class RedisMonitor < Scout::Plugin
  needs 'redis', 'yaml'

  OPTIONS = <<-EOS
  client_address:
    name: Address
    notes: Address of the Redis server
    default: 127.0.0.1
  client_port:
    name: Port
    notes: Redis port to pass to the client library.
    default: 6379
  client_db:
    name: Database
    notes: Redis database ID to pass to the client library.
    default: 0
  client_password:
    name: Password
    notes: If you're using Redis' password authentication.
  lists:
    name: Lists to monitor
    notes: A comma-separated list of list keys to monitor the length of.
  EOS

  KILOBYTE = 1024
  MEGABYTE = 1048576

  def build_report
    redis = Redis.new :port     => option(:client_port),
                      :host     => option(:client_address),
                      :db       => option(:db),
                      :password => option(:password)
    begin
      info = redis.info
    rescue Errno::ECONNREFUSED => error
      return error( "Could not connect to Redis.",
                    "Make certain you've specified correct port, DB and password." )
    end

    report(:uptime_in_hours   => info[:uptime_in_seconds].to_f / 60 / 60)
    report(:used_memory_in_mb => info[:used_memory].to_i / MEGABYTE)
    report(:used_memory_in_kb => info[:used_memory].to_i / KILOBYTE)

    counter(:connections_per_sec, info[:total_connections_received].to_i, :per => :second)
    counter(:commands_per_sec,    info[:total_commands_processed].to_i,   :per => :second)

    # General Stats
    %w(changes_since_last_save connected_clients connected_slaves bgsave_in_progress).each do |key|
      report(key => info[key.intern])
    end

    if option(:lists)
      lists = option(:lists).split(',')
      lists.each do |list|
        report("#{list} list length" => redis.llen(list))
      end
    end
  end

  private

  # Borrowed shamelessly from Eric Lindvall:
  # http://github.com/eric/scout-plugins/raw/master/iostat/iostat.rb
  def counter(name, value, options = {}, &block)
    current_time = Time.now

    if data = memory(name)
      last_time, last_value = data[:time], data[:value]
      elapsed_seconds       = current_time - last_time

      # We won't log it if the value has wrapped or enough time hasn't
      # elapsed
      unless value <= last_value || elapsed_seconds <= 1
        if block
          result = block.call(last_value, value)
        else
          result = value - last_value
        end

        case options[:per]
        when :second, 'second'
          result = result / elapsed_seconds.to_f
        when :minute, 'minute'
          result = result / elapsed_seconds.to_f / 60.0
        else
          raise "Unknown option for ':per': #{options[:per].inspect}"
        end

        if options[:round]
          # Backward compatibility
          options[:round] = 1 if options[:round] == true

          result = (result * (10 ** options[:round])).round / (10 ** options[:round]).to_f
        end

        report(name => result)
      end
    end

    remember(name => { :time => current_time, :value => value })
  end
end