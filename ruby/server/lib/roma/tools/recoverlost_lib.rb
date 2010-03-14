#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
# usage:recoverlost address port storage-path [yyyymmddhhmmss]
#
require 'roma/client/sender'
require 'roma/messaging/con_pool'
require 'roma/routing/routing_data'

module Roma
  module Storage
  end
  Storage::autoload(:TCStorage,'roma/storage/tc_storage')
  Storage::autoload(:DbmStorage,'roma/storage/dbm_storage')
  Storage::autoload(:SQLite3Storage,'roma/storage/sqlite3_storage')

  class RecoverLost
    
    def initialize(pname, pushv_cmd, argv, alldata = false)
      if alldata == false && argv.length < 4
        puts "usage:#{pname} address port storage-path [yyyymmddhhmmss]"
        exit
      end

      if alldata && argv.length != 3
        puts "usage:#{pname} address port storage-path"
        exit
      end

      @addr = argv[0]
      @port = argv[1]
      @strgpath = argv[2]
      @ymdhms = argv[3]

      if @port =~ /\D/
        STDERR.puts "port was not numeric."
        exit
      end
      
      if @ymdhms && (@ymdhms.length != 14 || @ymdhms =~ /\D/)
        STDERR.puts "yyyymmddhhmmss format mismatch."
        exit
      end
      @pushv_cmd = pushv_cmd
      @nodeid = "#{@addr}_#{@port}"
      @stream_copy_wait_param = 0.0001
      @alldata = alldata
    end

    def suite
      @rd = get_routing_data(@nodeid)
      unless @alldata
        @lost_vnodes = get_lost_vnodes(@rd,@ymdhms)
        puts "#{@lost_vnodes.length} vnodes where data was lost."

        exit if @lost_vnodes.length == 0
      else
        @lost_vnodes = @rd.v_idx.keys
      end

      each_hash(@strgpath){|hname,dir|
        puts "#{hname} #{dir}"
        @storage = open_storage(dir,@lost_vnodes)
        start_recover(hname)
        @storage.closedb
      }
    end

    def each_hash(path)
      Dir::glob("#{path}/*").each{|dir|
        next unless File::directory?(dir)
        hname = dir[dir.rindex('/')+1..-1]
        yield hname,dir
      }      
    end

    def get_routing_data(nid)
      sender = Roma::Client::Sender.new
      sender.send_routedump_command(nid)
    end

    def get_lost_vnodes(rd,ymdhms)
      ret = rd.get_lost_vnodes
      if ymdhms
        ret |= get_history_of_lost(rd.nodes[0],ymdhms)
      end
      ret
    end

    def get_history_of_lost(nid,ymdhms)
      ret = []
      con = Roma::Messaging::ConPool.instance.get_connection(nid)
      con.write("history_of_lost #{ymdhms}\r\n")
      while((buf = con.gets) != "END\r\n")
        ret << buf.chomp.to_i
      end
      Roma::Messaging::ConPool.instance.return_connection(nid, con)
      ret
    end

    def open_storage(path,vn_list)
      unless File::directory?(path)
        STDERR.puts "#{path} dose not found."
        return nil
      end

      # get a file extension
      ext = File::extname(Dir::glob("#{path}/0.*")[0])[1..-1]
      # count a number of divided files
      divnum = Dir::glob("#{path}/*.#{ext}").length
        
      st = new_storage(ext)
      st.divnum = divnum
      st.vn_list = vn_list
      st.storage_path = path
      st.opendb
      st
    end

    def new_storage(ext)
      case(ext)
      when 'tc'
        return ::Roma::Storage::TCStorage.new
      when 'dbm'
        return Roma::Storage::DbmStorage.new
      when 'sql3'
        return Roma::Storage::SQLite3Storage.new
      else
        return nil
      end
    end

    def start_recover(hname)
      @lost_vnodes.each_with_index{|vn, idx|
        nodes = @rd.v_idx[vn]
        if nodes == nil || nodes.length == 0
          nids = []
          nids[0] = @rd.nodes[rand(@rd.nodes.length)]
          puts "#{idx}/#{@lost_vnodes.length} #{vn} assign to #{nids.inspect}"
        else
          nids = nodes
          puts "#{idx}/#{@lost_vnodes.length} #{vn} was auto assirned at #{nids.inspect}"
        end

        nids.each{|nid|
          if push_a_vnode_stream(hname, vn, nid)!="STORED"
            STDERR.puts "push_a_vnode_stream aborted in #{vn}"
            exit
          end
        }

        if nodes == nil || nodes.length == 0
          cmd = "setroute #{vn} #{@rd.v_clk[vn]} #{nid}\r\n"
          exit unless send_cmd(nid ,cmd)
          broadcast_cmd(cmd, nid)
        end
      }
    end

    def push_a_vnode_stream(hname, vn, nid)
      con = Roma::Messaging::ConPool.instance.get_connection(nid)

      con.write("#{@pushv_cmd} #{hname} #{vn}\r\n")

      res = con.gets # READY\r\n or error string
      if res != "READY\r\n"
        con.close
        return res.chomp
      end

      @storage.each_vn_dump(vn){|data|
        con.write(clk_to_zero(data))
        sleep @stream_copy_wait_param
      }
      con.write("\0"*20) # end of steram

      res = con.gets # STORED\r\n or error string
      Roma::Messaging::ConPool.instance.return_connection(nid,con)
      res.chomp! if res
      res
    rescue =>e
      STDERR.puts "#{e}\n#{$@}"
      nil
    end

    def clk_to_zero(data)
      vn, last, clk, expt, klen = data.unpack('NNNNN')
      k, vlen = data[20..-1].unpack("a#{klen}N")
      if vlen != 0
        v, = data[(20+klen+4)..-1].unpack("a#{vlen}")
        [vn, last, 0, expt, klen, k, vlen, v].pack("NNNNNa#{klen}Na#{vlen}")
      else
        [vn, last, 0, expt, klen, k, 0].pack("NNNNNa#{klen}N")
      end
    end

    def broadcast_cmd(cmd,without_nids=nil)
      without_nids=[] unless without_nids
      res = {}
      @rd.nodes.each{ |nid|
        res[nid] = send_cmd(nid,cmd) unless without_nids.include?(nid)
      }
      res
    rescue => e
      STDERR.puts("#{e}\n#{$@}")
      nil
    end

    def send_cmd(nid, cmd)
      con = Roma::Messaging::ConPool.instance.get_connection(nid)
      con.write(cmd)
      res = con.gets
      Roma::Messaging::ConPool.instance.return_connection(nid, con)
      if res
        res.chomp!
      end
      res
    rescue => e
      STDERR.puts("#{__FILE__}:#{__LINE__}:Send command failed that node-id is #{nid},command is #{cmd}.")
      nil
    end

  end # class RecoverLost
end # module Roma
