module Fluent
  class Ping < Input
    Plugin.register_input('ping', self)
    include DetachMultiProcessMixin

    def initialize
      super
    end

    config_param :port, :integer, :default => 9880
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
        @lsock = Coolio::TCPServer.new(@bind, @port, Handler, @km, method(:on_request), @body_size_limit)
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
        if path == "/ping"
          return ["200 OK", {'Content-type'=>'text/plain'}, "{\"status\":\"ok\"}\n"]
        end
      rescue
        return ["404 Not Found", {'Content-type'=>'text/plain'}, "404 Not Found\n"]
      end
    end

  end
end

