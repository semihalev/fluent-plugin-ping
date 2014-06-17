module Fluent
  class Ping < Fluent::Input
    Plugin.register_input('ping', self)
    include DetachMultiProcessMixin

    require 'http/parser'

    def initialize
      require 'webrick/httputils'
      require 'uri'
      super
    end

    config_param :port, :integer, :default => 8101
    config_param :bind, :string, :default => '0.0.0.0'
    config_param :body_size_limit, :size, :default => 32*1024*1024  # TODO default
    config_param :keepalive_timeout, :time, :default => 10   # TODO default
    config_param :backlog, :integer, :default => nil

    def configure(conf)
      super
    end

    class KeepaliveManager < Coolio::TimerWatcher
      def initialize(timeout)
        super(1, true)
        @cons = {}
        @timeout = timeout.to_i
      end

      def add(sock)
        @cons[sock] = sock
      end

      def delete(sock)
        @cons.delete(sock)
      end

      def on_timer
        @cons.each_pair {|sock,val|
          if sock.step_idle > @timeout
            sock.close
          end
        }
      end
    end

    def start
      log.debug "ping listening http on #{@bind}:#{@port}"
      lsock = TCPServer.new(@bind, @port)

      detach_multi_process do
        super
        @km = KeepaliveManager.new(@keepalive_timeout)
        @lsock = Coolio::TCPServer.new(lsock, nil, Handler, @km, method(:on_request), @body_size_limit, log)
        @lsock.listen(@backlog) unless @backlog.nil?

        @loop = Coolio::Loop.new
        @loop.attach(@km)
        @loop.attach(@lsock)

        @thread = Thread.new(&method(:run))
      end
    end

    def shutdown
      @loop.watchers.each {|w| w.detach }
      @loop.stop
      @lsock.close
      @thread.join
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def on_request(path_info, params)
      begin
        if path_info == "/ping"
          return ["200 OK", {'Content-type'=>'text/plain'}, '{"status":"ok"}']
	else
          return ["404 Not Found", {'Content-type'=>'text/plain'}, "404 Not Found"]
        end
      rescue
        return ["500 Internal Server Error", {'Content-type'=>'text/plain'}, "500 Internal Server Error"]
      end
    end

    class Handler < Coolio::Socket
      def initialize(io, km, callback, body_size_limit, log)
        super(io)
        @km = km
        @callback = callback
        @body_size_limit = body_size_limit
        @content_type = ""
        @next_close = false
        @log = log

        @idle = 0
        @km.add(self)

        @remote_port, @remote_addr = *Socket.unpack_sockaddr_in(io.getpeername) rescue nil
      end

      def step_idle
        @idle += 1
      end

      def on_close
        @km.delete(self)
      end

      def on_connect
        @parser = Http::Parser.new(self)
      end

      def on_read(data)
        @idle = 0
        @parser << data
      rescue
        @log.warn "unexpected error", :error=>$!.to_s
        @log.warn_backtrace
        close
      end

      def on_message_begin
        @body = ''
      end

      def on_headers_complete(headers)
        expect = nil
        size = nil
        if @parser.http_version == [1, 1]
          @keep_alive = true
        else
          @keep_alive = false
        end
        @env = {}
        headers.each_pair {|k,v|
          @env["HTTP_#{k.gsub('-','_').upcase}"] = v
          case k
          when /Expect/i
            expect = v
          when /Content-Length/i
            size = v.to_i
          when /Content-Type/i
            @content_type = v
          when /Connection/i
            if v =~ /close/i
              @keep_alive = false
            elsif v =~ /Keep-alive/i
              @keep_alive = true
            end
          end
        }
        if expect
          if expect == '100-continue'
            if !size || size < @body_size_limit
              send_response_nobody("100 Continue", {})
            else
              send_response_and_close("413 Request Entity Too Large", {}, "Too large")
            end
          else
            send_response_and_close("417 Expectation Failed", {}, "")
          end
        end
      end

      def on_body(chunk)
        if @body.bytesize + chunk.bytesize > @body_size_limit
          unless closing?
            send_response_and_close("413 Request Entity Too Large", {}, "Too large")
          end
          return
        end
        @body << chunk
      end

      def on_message_complete
        return if closing?

        @env['REMOTE_ADDR'] = @remote_addr if @remote_addr

        uri = URI.parse(@parser.request_url)
        params = WEBrick::HTTPUtils.parse_query(uri.query)

        params.merge!(@env)
        @env.clear
        path_info = uri.path

        code, header, body = *@callback.call(path_info, params)
        body = body.to_s

        if @keep_alive
          header['Connection'] = 'Keep-Alive'
          send_response(code, header, body)
        else
          send_response_and_close(code, header, body)
        end
      end

      def on_write_complete
        close if @next_close
      end

      def send_response_and_close(code, header, body)
        send_response(code, header, body)
        @next_close = true
      end

      def closing?
        @next_close
      end

      def send_response(code, header, body)
        header['Content-length'] ||= body.bytesize
        header['Content-type'] ||= 'text/plain'

        data = %[HTTP/1.1 #{code}\r\n]
        header.each_pair {|k,v|
          data << "#{k}: #{v}\r\n"
        }
        data << "\r\n"
        write data

        write body
      end

      def send_response_nobody(code, header)
        data = %[HTTP/1.1 #{code}\r\n]
        header.each_pair {|k,v|
          data << "#{k}: #{v}\r\n"
        }
        data << "\r\n"
        write data
      end
    end

  end
end
