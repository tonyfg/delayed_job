unless ENV['RAILS_ENV'] == 'test'
  begin
    require 'daemons'
  rescue LoadError
    raise "You need to add gem 'daemons' to your Gemfile if you wish to use it."
  end
end
require 'optparse'

module Delayed
  class Command
    attr_accessor :worker_count, :worker_pools

    def initialize(args)
      @options = {
        :quiet => true,
        :pid_dir => "#{Rails.root}/tmp/pids"
      }

      @worker_count = 1
      @monitor = false

      opts = OptionParser.new do |opt|
        opt.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] start|stop|restart|run"

        opt.on('-h', '--help', 'Show this message') do
          puts opt
          exit 1
        end
        opt.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |_e|
          STDERR.puts 'The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/#issue/7'
        end
        opt.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = n
        end
        opt.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = n
        end
        opt.on('-n', '--number_of_workers=workers', 'Number of unique workers to spawn') do |worker_count|
          @worker_count = worker_count.to_i rescue 1 # rubocop:disable RescueModifier
        end
        opt.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opt.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opt.on('-m', '--monitor', 'Start monitor process.') do
          @monitor = true
        end
        opt.on('--sleep-delay N', 'Amount of time to sleep when no jobs are found') do |n|
          @options[:sleep_delay] = n.to_i
        end
        opt.on('--read-ahead N', 'Number of jobs from the queue to consider') do |n|
          @options[:read_ahead] = n
        end
        opt.on('-p', '--prefix NAME', 'String to be prefixed to worker process names') do |prefix|
          @options[:prefix] = prefix
        end
        opt.on('--queues=queues', 'Specify which queue DJ must look up for jobs') do |queues|
          @options[:queues] = queues.split(',')
        end
        opt.on('--queue=queue', 'Specify which queue DJ must look up for jobs') do |queue|
          @options[:queues] = queue.split(',')
        end
        opt.on('--pools=queue1,queue2:workers/queue3:workers', "Specify queues and number of workers for multiple worker pools") do |pools|
          parse_worker_pools(pools)
        end
        opt.on('--exit-on-complete', 'Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.') do
          @options[:exit_on_complete] = true
        end
      end
      @args = opts.parse!(args)
    end

    def daemonize
      dir = @options[:pid_dir]
      Dir.mkdir(dir) unless File.exist?(dir)

      if @worker_pools
        worker_index = 0
        @worker_pools.each do |queues, worker_count|
          options = @options.merge(:queues => queues)
          worker_count.times do
            process_name = "delayed_job.#{worker_index}"
            run_process(process_name, options)
            worker_index += 1
          end
        end

      elsif @worker_count > 1 && @options[:identifier]
        fail(ArgumentError.new('Cannot specify both --number-of-workers and --identifier'))

      elsif @worker_count == 1 && @options[:identifier]
        process_name = "delayed_job.#{@options[:identifier]}"
        run_process(process_name, @options)

      else
        worker_count.times do |worker_index|
          process_name = worker_count == 1 ? "delayed_job" : "delayed_job.#{worker_index}"
          run_process(process_name, @options)
        end
      end
    end

    def run_process(process_name, options = {})
      Delayed::Worker.before_fork
      Daemons.run_proc(process_name, :dir => options[:pid_dir], :dir_mode => :normal, :monitor => @monitor, :ARGV => @args) do |*args|
        $0 = File.join(options[:prefix], process_name) if @options[:prefix]
        run process_name
      end
    end

    def run(worker_name = nil, options = {})
      Dir.chdir(Rails.root)

      Delayed::Worker.after_fork
      Delayed::Worker.logger ||= Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))

      worker = Delayed::Worker.new(options)
      worker.name_prefix = "#{worker_name} "
      worker.start
    rescue => e
      Rails.logger.fatal e
      STDERR.puts e.message
      exit 1
    end


    private

    def parse_worker_pools(pools)
      @worker_pools = pools.split('/').map do |pool|
        queues, worker_count = pool.split(':')
        if ['*', '', nil].include?(queues)
          queues = []
        else
          queues = queues.split(',')
        end
        worker_count = worker_count.to_i rescue 1
        [queues, worker_count]
      end
    end
  end
end
