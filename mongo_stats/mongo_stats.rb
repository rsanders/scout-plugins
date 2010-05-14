require "time"
require "digest/md5"

# MongoDB Slow Queries Monitoring plug in for scout.
# Created by Jacob Harris, based on the MySQL slow queries plugin

class ScoutMongoStats < Scout::Plugin
  needs "mongo"

  OPTIONS=<<-EOS
    database:
      name: Mongo Database
      notes: Name of the MongoDB database to authenticate to
      default: admin
    server:
      name: Mongo Server
      notes: Where mongodb is running
      default: localhost
    port:
      name: Mongo Server Port
      notes: Where mongodb is running
      default: 27017
    username:
      notes: leave blank unless you have authentication enabled
    password:
      notes: leave blank unless you have authentication enabled
  EOS

  KILOBYTE = 1024
  MEGABYTE = 1048576

  
  def build_report
    database = option("database").to_s.strip
    server = option("server").to_s.strip
    port = option("port") ? (option("port").strip.to_i rescue 27017) : 27017
    
    if server.empty?
      server = "localhost"
    end

    if database.empty?
      database = "admin"
    end

    db = Mongo::Connection.new(server, port)  # .db(database)
    db.authenticate(option(:username), option(:password)) if !option(:username).to_s.empty?

    last_run = memory(:last_run) || Time.now
    current_time = Time.now

    stats = db['admin'].command({:serverStatus => 1}, true)   

    # 
    # {"uptime"=>223.0, "localTime"=>Fri May 14 03:03:33 UTC 2010, 
    #   "globalLock"=>{"totalTime"=>223163371.0, "lockTime"=>49034.0, "ratio"=>0.000219722438231138},
    #   "mem"=>{"resident"=>2, "virtual"=>2396, "supported"=>true, "mapped"=>0}, 
    #   "connections"=>{"current"=>2, "available"=>19998}, 
    #   "extra_info"=>{"note"=>"fields vary by platform"}, 
    #   "indexCounters"=>{"btree"=>{"accesses"=>0, "hits"=>0, "misses"=>0, "resets"=>0, "missRatio"=>0.0}},
    #   "backgroundFlushing"=>{"flushes"=>3, "total_ms"=>0, "average_ms"=>0.0, "last_ms"=>0, 
    #       "last_finished"=>"Fri May 14 03:02:50 UTC 2010"}, 
    #   "opcounters"=>{"insert"=>0, "query"=>1, "update"=>0, "delete"=>0, "getmore"=>0, "command"=>3},
    #   "asserts"=>{"regular"=>0, "warning"=>0, "msg"=>0, "user"=>0, "rollovers"=>0}, 
    #   "ok"=>1.0}    

    elapsed_seconds = current_time - last_run
    elapsed_seconds = 1 if elapsed_seconds < 1

    report(:uptime_in_hours   => stats['uptime'].to_f / 3600)
    
    report(:resident_memory_in_mb => stats['mem']['resident'].to_i)
    report(:virtual_memory_in_mb => stats['mem']['virtual'].to_i)
    report(:mapped_memory_in_mb => stats['mem']['mapped'].to_i)

    report(:current_connections => stats['connections']['current'].to_i)
    report(:available_connections => stats['connections']['available'].to_i)

    # report(:page_faults => stats['extra']['mapped'].to_i)

    btreeCounters = stats['indexCounters']['btree'] rescue nil
    if btreeCounters
      ['accesses', 'hits', 'misses'].each do |ctr|
        counter("index_btree_#{ctr}_per_sec".to_sym, btreeCounters[ctr].to_i, :per => :second)
      end
    end
    
    opcounters = stats['opcounters']
    if opcounters
      ["insert", "query", "update", "delete", "getmore", "command"].each do |ctr|
        counter("opcount_#{ctr}_per_sec".to_sym, opcounters[ctr].to_i, :per => :second)
      end
    end

    asserts = stats['asserts'] rescue nil
    if asserts
      ["regular", "warning", "msg", "user", "rollovers"].each do |ctr|
        counter("assert_#{ctr}_per_sec".to_sym, asserts[ctr].to_i, :per => :second)
      end
    end

    # todo - flush stats, locktime, total time, page faults (on Linux)

    report(:lock_percentage => stats['globalLock']['ratio'].to_f * 100)

    remember(:last_run,Time.now)
  rescue Mongo::MongoDBError => error
    error("A Mongo DB error has occurred: #{error.message}.", "A Mongo DB error has occurred: #{error.message}")
  rescue RuntimeError => error
    if error.message =~/Error with command.+unauthorized/i
      error("Invalid MongoDB Authentication", "The username/password for your MongoDB database are incorrect")
      return
    else
      raise error
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
