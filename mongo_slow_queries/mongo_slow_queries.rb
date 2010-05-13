require "time"
require "digest/md5"

# MongoDB Slow Queries Monitoring plug in for scout.
# Created by Jacob Harris, based on the MySQL slow queries plugin

class ScoutMongoSlow < Scout::Plugin
  needs "mongo"

  OPTIONS=<<-EOS
    database:
      name: Mongo Database
      notes: Name of the MongoDB database to profile
    server:
      name: Mongo Server
      notes: Where mongodb is running
      default: localhost
    port:
      name: Mongo Server Port
      notes: Where mongodb is running
      default: 27017
    threshold:
      name: Threshold (millisecs)
      notes: Slow queries are >= this time in milliseconds to execute (min. 100)
      default: 100
    username:
      notes: leave blank unless you have authentication enabled
    password:
      notes: leave blank unless you have authentication enabled
  EOS

  def enable_profiling(db)
    # set to slow_only or higher (>100ms)
    if db.profiling_level == :off
      db.profiling_level = :slow_only
    end
  end
  
  def build_report
    database = option("database").to_s.strip
    server = option("server").to_s.strip
    port = option("port").to_s.strip.to_i rescue 27017
    
    if server.empty?
      server ||= "localhost"
    end
    
    if database.empty?
      return error( "A Mongo database name was not provided.",
                    "Slow query logging requires you to specify the database to profile." )
    end

    threshold_str = option("threshold").to_s.strip
    if threshold_str.empty?
      threshold = 100
    else
      threshold = threshold_str.to_i
    end

    db = Mongo::Connection.new(server, port).db(database)
    db.authenticate(option(:username), option(:password)) if !option(:username).to_s.empty?
    enable_profiling(db)

    slow_queries = []
    last_run = memory(:last_run) || Time.now
    current_time = Time.now
    
    # info
    selector = { 'millis' => { '$gte' => threshold } }
    cursor = Mongo::Cursor.new(Mongo::Collection.new(db, Mongo::DB::SYSTEM_PROFILE_COLLECTION), :selector => selector).limit(20).sort([["$natural", "descending"]])
    
    # reads most recent first
    # {"ts"=>Wed Dec 16 02:44:03 UTC 2009, "info"=>"query twitter_follow.system.profile ntoreturn:0 reslen:1236 nscanned:8  \nquery: { query: { millis: { $gte: 5 } }, orderby: { $natural: -1 } }  nreturned:8 bytes:1220", "millis"=>57.0}
    cursor.each do |prof|
      ts = prof['ts']
      break if ts < last_run
      
      slow_queries << prof
    end

    elapsed_seconds = current_time - last_run
    elapsed_seconds = 1 if elapsed_seconds < 1
    # calculate per-second
    report(:slow_queries => slow_queries.size/(elapsed_seconds/60.to_f))
    
    if slow_queries.any?
      alert(build_alert(slow_queries))
    end
    remember(:last_run,Time.now)
  rescue Mongo::MongoDBError => error
    error("A Mongo DB error has occurred.", "A Mongo DB error has occurred")
  rescue RuntimeError => error
    if error.message =~/Error with profile command.+unauthorized/i
      error("Invalid MongoDB Authentication", "The username/password for your MongoDB database are incorrect")
      return
    else
      raise error
    end  
  end
  
  def build_alert(slow_queries)
    subj = "Maximum Query Time exceeded on #{slow_queries.size} #{slow_queries.size > 1 ? 'queries' : 'query'}"
    
    body = String.new
    slow_queries.each do |sq|
      body << "<strong>#{sq["millis"]} millisec query on #{sq['ts']}:</strong>\n"
      body << sq['info']
      body << "\n\n"
    end # slow_queries.each
    {:subject => subj, :body => body}
  end # build_alert
end
