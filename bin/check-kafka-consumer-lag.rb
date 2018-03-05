#! /usr/bin/env ruby
#
# check-consumer-lag
#
# DESCRIPTION:
#   This plugin checks the lag of your kafka's consumers.
#
# OUTPUT:
#   plain-text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# USAGE:
#   ./check-consumer-lag
#
# NOTES:
#
# LICENSE:
#   Olivier Bazoud
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugin/check/cli'

class ConsumerLagCheck < Sensu::Plugin::Check::CLI
  option :group,
         description: 'Consumer group',
         short:       '-g NAME',
         long:        '--group NAME',
         required:    true

  option :kafka_home,
         description: 'Kafka home',
         short:       '-k NAME',
         long:        '--kafka-home NAME',
         default:     '/opt/kafka'

  option :topic_excludes,
         description: 'Excludes consumer topics',
         short:       '-e NAME',
         long:        '--topic-excludes NAME',
         proc:        proc { |a| a.split(',') }

  option :autolist,
         description: 'Auto list topics',
         short:       '-a VALUE',
         long:        '--auto-list VALUE',
         boolean: true,
         default: true

  option :new_consumer,
         description: 'Uses the new consumer',
         short:       '-n VALUE',
         long:        '--new-consumer VALUE',
         boolean: true,
         default: true

  option :zookeeper,
         description: 'ZooKeeper connect string',
         short:       '-z NAME',
         long:        '--zookeeper NAME',
         default:     'localhost:2181'

  option :bootstrap_server,
         description: 'BootStrap connect string',
         short:       '-b NAME',
         long:        '--bootstrap-server NAME',
         default:     'localhost:9092'

  option :warning_over,
         description: 'Warning if metric statistics is over specified value.',
         short:       '-W N',
         long:        '--warning-over N'

  option :critical_over,
         description: 'Critical if metric statistics is over specified value.',
         short:       '-C N',
         long:        '--critical-over N'

  option :warning_under,
         description: 'Warning if metric statistics is under specified value.',
         short:       '-w N',
         long:        '--warning-under N'

  option :critical_under,
         description: 'Critical if metric statistics is under specified value.',
         short:       '-c N',
         long:        '--critical-under N'

  # read the output of a command
  # @param cmd [String] the command to read the output from
  def read_lines(cmd)
    IO.popen(cmd + ' 2>&1') do |child|
      child.read.split("\n")
    end
  end

  # create a hash from the output of each line of a command
  # @param line [String]
  # @param cols
  def line_to_hash(line, *cols)
    Hash[cols.zip(line.strip.split(/\s+/, cols.size))]
  end

  # run command and return a hash from the output
  # @param cms [String]
  def run_offset(cmd)
    read_lines(cmd).drop(1).map do |line|
      line_to_hash(line, :group, :topic, :pid, :offset, :logsize, :lag, :owner)
    end
  end

  # run command and return a hash from the output
  # @param cms [String]
  def run_topics(cmd)
    topics = []
    read_lines(cmd).map do |line|
      if !line.include?('__consumer_offsets') && !line.include?('marked for deletion')
        topics.push(line)
      end
    end
    topics
  end

  def run
    kafka_run_class = "#{config[:kafka_home]}/bin/kafka-run-class.sh"
    unknown "Can not find #{kafka_run_class}" unless File.exist?(kafka_run_class)

    topics_to_read = []
    if config[:autolist].to_s == 'true'
      cmd_topics = "#{kafka_run_class} kafka.admin.TopicCommand --zookeeper #{config[:zookeeper]} --list"
      topics_to_read = run_topics(cmd_topics)
      topics_to_read.delete_if { |x| config[:topic_excludes].include?(x) } if config[:topic_excludes]
    end

    if config[:new_consumer].to_s == 'true'
      cmd_offset = "#{kafka_run_class} kafka.admin.ConsumerGroupCommand --describe --group #{config[:group]} --bootstrap-server #{config[:bootstrap_server]}"
    else
      cmd_offset = "#{kafka_run_class} kafka.tools.ConsumerOffsetChecker --group #{config[:group]} --zookeeper #{config[:zookeeper]}"
      cmd_offset += " --topic #{topics_to_read.join(',')}" unless topics_to_read.empty?
    end

    topics = run_offset(cmd_offset).group_by { |h| h[:topic] }

    critical "Could not found topics/partitions" if topics.empty?

    # [:offset, :logsize, :lag].each do |field|
    [:offset, :logsize].each do |field|
        topics.map do |k, v|
        critical "Topic #{k} has partitions with #{field} < 0" unless v.select { |w| w[field].to_i < 0 }.empty?
      end
    end

    topics.map do |k, v|
      critical "Topic #{k} has partitions with no owner" unless v.select { |w| w[:owner] == 'none' }.empty?
    end

    lags = topics.map do |k, v|
      Hash[k, v.inject(0) { |a, e| a + e[:lag].to_i }]
    end

    max_lag = lags.map(&:values).flatten.max
    max_topics = lags.select { |a| a.key(max_lag) }.map(&:keys).flatten

    min_lag = lags.map(&:values).flatten.min
    min_topics = lags.select { |a| a.key(min_lag) }.map(&:keys).flatten

    [:over, :under].each do |over_or_under|
      [:critical, :warning].each do |severity|
        threshold = config[:"#{severity}_#{over_or_under}"]

        next unless threshold
        case over_or_under
        when :over
          if max_lag > threshold.to_i
            msg = "Topics `#{max_topics}` for the group `#{config[:group]}` lag: #{max_lag} (>= #{threshold})"
            send severity, msg
          end
        when :under
          if min_lag < threshold.to_i
            msg =  "Topics `#{min_topics}` for the group `#{config[:group]}` lag: #{min_lag} (<= #{threshold})"
            send severity, msg
          end
        end
      end
    end

    ok "Group `#{config[:group]}`'s lag is ok (#{min_lag}/#{max_lag})"

  rescue => e
    puts "Error: exception: #{e} - #{e.backtrace}"
    critical
  end
end
