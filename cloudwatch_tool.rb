#!/usr/bin/ruby
# -*- coding: utf-8 -*-

#gem install aws-sdk

require 'singleton'
require 'optparse'
require 'aws-sdk'

class AwsClient
  include Singleton

  Aws.config.update ({
    region: '??',
    credentials: Aws::Credentials.new('??', '??'),
  })

  def initialize
    @cloudwatch = Aws::CloudWatch::Client.new
    @ec2 = Aws::EC2::Client.new
  end

  def retrieve_cloudwatch_metrics
    puts 'Retrieve all CloudWatch metrics ...'
    list = @cloudwatch.list_metrics.map{|r| r.data.metrics}.flatten 1
    puts "#{list.size} records are received."
    list
  end

  def retrieve_ec2_tags(tags)
    puts 'Retrieve follow tags from AWS ... ' + tags.to_s
    tags = @ec2.describe_tags(:filters=>[{:name=>'key', :values=>tags}]).data.tags
    puts "#{tags.size} records are received."
    Hash[tags.map {|x| [x.resource_id, x]}]
  end
end

class CommandShell
  def ask
    @done = false
    begin
      prompt
    end until @done
  end
  
  def prompt(shows_status = true)
    put_status if shows_status
    puts help_message
    
    begin
      print '> '
    end until process_command $stdin.gets.chomp.strip
  end

  def process_command(input_command)
    input_command = input_command.to_s
    return nil if input_command.to_s.empty?

    command = "command_#{input_command.to_s.downcase}"
    return send(command) || '' if methods.include? command.to_sym

    puts "Unknown command '#{input_command}'" # puts returns nil always
  end

  def help_message
    'There is no subcommand here'
  end

  def command_h
  end

  def put_status
  end

  def done
    @done = true
  end
end

class SelectCommandShell < CommandShell
  def initialize
    @selection = Set.new
  end

  def clear
    @selection.clear
  end

  attr_reader :selection

  def toggle_selection(keyword)
    unless toggle_by_index(keyword) || toggle_by_name(keyword)
      puts "Invalid name or index '#{keyword}''. Selected item didn't changed."
    end
  end

  def toggle_by_index(keyword)
    (/^\d+$/.match keyword) && (key = @display_index[keyword.to_i]) && (toggle_by_key key)
  end

  def toggle_by_name(keyword)
    if /^\/.*\/$/.match keyword # match up as regexp
      re = Regexp.new(keyword.slice(1..-2), Regexp::IGNORECASE)
      items.select {|x| re.match x[:name]}
    else
      items.select {|x| keyword.to_s.casecmp(x[:name]).zero? }
    end.each {|x| toggle_by_key x[:key]}.size > 0
  end

  def toggle_by_key(key)
    if @selection.include? key
      @selection.delete key
    else
      @selection.add key
    end
  end

  def format(item)
    (item.include? :name)? item[:name]: item[:key]
  end

  def put_status(with_detail)
    puts "Selected items: #{@selection.to_a}"
  end

  def prompt
    puts help_message

    @display_index = []

    items.each_with_index do | x, i |
      @display_index[i] = x[:key]
      s = (@selection.include? x[:key])? '*': ' '
      puts '%-1s[%d]: %s' % [s, i, format(x)]
    end
    print '(separate with comma, enter a space to finish) > '

    if (input = $stdin.gets.chomp.strip).empty?
      done # ask_done when it's important
    else
      input.split(',').each {|x| toggle_selection x}
    end    
  end

  def ask_done
    print 'Are you done? (empty input = yes) '
    x = $stdin.gets.chomp.strip
    done if x.nil? || x.empty? || input.casecmp('y') || input.casecmp('yes')
  end
end

class PropertyCommandShell < CommandShell
  def initialize
    command_clear
  end
  
  def prompt
    puts help_message

    properties.each_with_index do |x, i|
      puts '[%d]: %s = %s' % [i, x[:name], @instance[x[:name]]]
    end
    print '(select number or property name to set. "/clear" to reset all to defaut.) > '

    if (input = $stdin.gets.chomp.strip).empty?
      done # ask_done when it's important
    elsif input.start_with? '/'
      process_command input.slice(1..-1)
    else
      edit_property(input)
    end    
  end

  def edit_property(property_key)
    prop = get_property(property_key)
    unless prop && (property_name = prop[:name])
      puts "Invalid property index or name '#{property_key}'"
      return
    end

    puts "Enter a value for property '#{property_name}'. (#{prop[:desc]})"
    puts "Current value is '#{@instance[property_name]}'"
    if prop.include? :values
      puts 'Available values'
      prop[:values].each_with_index {|x,i| puts '  [%d]: %s' % [i, x]}
    end

    begin
      print "#{property_name} = "
    end until set_property(prop, $stdin.gets.chomp.strip)
  end

  def set_property(prop, value)
    return @instance[prop[:name]] = value unless prop.include? :values

    valid_value = (/^\d+$/.match value)? prop[:values][value.to_i]: prop[:values].find {|v| v.casecmp(value)}
    if valid_value
      (@instance[prop[:name]] = valid_value) || ''
    else
      puts "Prop #{prop[:name]} can't be '#{value}'."
    end
  end

  def get_property(keyword)
    return properties[keyword.to_i] if (/^\d+$/.match keyword)
    properties.select {|p| (name = p[:name]) && name.casecmp(keyword).zero?}.first
  end

  def command_clear
    @instance = properties.inject({}) {|h, p| h.merge(p[:name] => p[:default])}
  end

  def help_message
  end

  def put_status(with_detail=true)
    properties.each do |x|
      if with_detail
        puts '%s = %s (default: %s)' % [x[:name], @instance[x[:name]], x[:default]]
      else
        puts '%s = %s' % [x[:name], @instance[x[:name]]]
      end
    end
  end
end

class MetricSelectCommandShell < SelectCommandShell
  def initialize(metrics)
    super()
    @items = metrics.map do |x|
      {
        :key => x.metric_name,
        :name => x.metric_name,
      }
    end.uniq.sort_by {|x| x[:key]}
  end

  attr_reader :items

  def help_message
'
To select metrics, enter number or exact name (Wildcards are not supported)
You can move to next step by enter a space when you are done.
'
  end
end

class InstanceSelectCommandShell < SelectCommandShell
  REQUIRED_RESOURCES = %w(VolumeId InstanceId)

  def initialize(metrics)
    super()

    @tags = AwsClient.instance.retrieve_ec2_tags ['Name']
    @items = metrics.select{|x| x.dimensions}.map do |m|
      m.dimensions.select{|x| REQUIRED_RESOURCES.include? x.name}.map do |d|
        {
          :key => '%s:%s' % [d.value, m.metric_name],
          :name => d.value,
          :resource_name => @tags.include?(d.value)? @tags[d.value].value: nil,
          :name_space => m.namespace,
          :metric => m.metric_name,
        }
      end
    end.flatten 1
    @item_map = Hash[@items.map {|x| [x[:key], x]}]
  
    @filter = Set.new
  end

  def help_message
"
To select instances, enter number or exact id of instance (Wildcards are not supported)
You can move to next step by enter a space when you are done.
It will shows instances with these metrics : #{@filter.to_a}
"
  end

  def format(item)
    '%s (%s) - %s' % [item[:name], item[:resource_name], item[:metric]]
  end

  def format_simple(item)
    '%s(%s)' % [item[:name], item[:resource_name]]
  end

  def put_status(with_detail)
    if with_detail
      puts 'Selected instances {{{', @selection.map{|key| format @item_map[key]}, '}}}'
    else
      puts 'Selected instances: ' + @selection.map{|key| format_simple @item_map[key]}.join(', ')
    end
  end

  def items
    @items.select {|x| @filter.include? x[:metric]}
  end

  def filter=(filter)
    @filter = filter
    @selection.select! {|key| (item = @item_map[key]) && filter.include?(item[:metric])}
  end
end

class AlarmPropertyCommandShell < PropertyCommandShell
  PROPERTIES =
    [
     { name: 'alarm_prefix', desc: %q[The descriptive prefix for the alarm. This combination of this prefix and resource and metric name must be unique within the user's AWS account.], default: Time.new.strftime('%m%d-%H%M%S:') },
     { name: 'alarm_description', desc: %q[The description for the alarm.], default: nil },
     { name: 'actions_enabled', desc: %q[Indicates whether or not actions should be executed during any changes to the alarm's state.], values: [true, false], default: true },
     { name: 'ok_sns_topic', desc: %q[The list of sns topic to execute when this alarm transitions into an OK state from any other state.], values: ['grape-server-developers'], default: 'grape-server-developers' },
     { name: 'alarm_sns_topic', desc: %q[The list of sns topic to execute when this alarm transitions into an ALARM state from any other state.], values: ['grape-server-developers'], default: 'grape-server-developers' },
     { name: 'insufficient_sns_topic', desc: %q[The list of sns topic to execute when this alarm transitions into an INSUFFICIENT_DATA state from any other state.], values: ['grape-server-developers'], default: 'grape-server-developers' },
     { name: 'statistic', desc: %q[The statistic to apply to the alarm's associated metric.], values: %w[SampleCount Average Sum Minimum Maximum], default: 'Average' },
     { name: 'period', desc: %q[The period in seconds over which the specified statistic is applied.], default: 1},
     { name: 'unit', desc: %q[The unit for the alarm's associated metric.], values: %w[Seconds Microseconds Milliseconds Bytes Kilobytes Megabytes Gigabytes Terabytes Bits Kilobits Megabits Gigabits Terabits Percent Count Bytes/Second Kilobytes/Second Megabytes/Second Gigabytes/Second Terabytes/Second Bits/Second Kilobits/Second Megabits/Second Gigabits/Second Terabits/Second Count/Second None], default: 'Count'},
     { name: 'evaluation_periods', desc: %q[The number of periods over which data is compared to the specified threshold.], default: 1 },
     { name: 'threshold', desc: %q[The value against which the specified statistic is compared.], default: 0.0 },
     { name: 'comparison_operator', desc: %q[The arithmetic operation to use when comparing the specified Statistic and Threshold. The specified Statistic value is used as the first operand.], values: %w[GreaterThanOrEqualToThreshold GreaterThanThreshold LessThanThreshold LessThanOrEqualToThreshold], default: 'GreaterThanOrEqualToThreshold' },
    ]

  def properties
    PROPERTIES
  end

  def put_status(with_detail=true)
    puts 'Current configurations for new CloudWatch Alarm {{{'
    super(with_detail)
    puts '}}}'
  end
end

class AddCloudWatchAlarmCommandShell < CommandShell
  def initialize
    super
    @metrics = AwsClient.instance.retrieve_cloudwatch_metrics

    @shell_select_metric = MetricSelectCommandShell.new(@metrics)
    @shell_select_instance = InstanceSelectCommandShell.new(@metrics)
    @shell_alarm_property = AlarmPropertyCommandShell.new
  end
   
  def help_message
'
 [S]elect metrics and instances
 [E]dit properties of alarm
 [P]rint changes on editing
 [A]pply current changes to the CloudWatch on AWS

 Ignore current setting and [Q]uit
'
  end

  def ask
    command_s
    super
  end

  def put_status(with_detail=false)
    @shell_select_instance.put_status with_detail
    puts
    @shell_alarm_property.put_status with_detail
  end

  def command_s
    @shell_select_metric.ask
    @shell_select_instance.filter = @shell_select_metric.selection
    @shell_select_instance.ask
  end

  def command_e
    @shell_alarm_property.ask
  end

  def command_p
    put_status true
    prompt false
  end

  def command_a
    puts 'Apply'

    command_q
  end

  def command_q
    @shell_select_metric.clear
    @shell_select_instance.clear

    done
  end
end

class MainCommandShell < CommandShell
  def initialize
    @shell_add = AddCloudWatchAlarmCommandShell.new
    @shell_delete = CommandShell.new
  end 
  
  def help_message
'
Commands
  [A]dd CloudWatch alarm by current settings
  [E]nable/disable CloudWatch alarms
  [D]elete CloudWatch alarms

  [Q]uit
'
  end

  def command_a
    @shell_add.ask
  end

  def command_e
    puts "Not yet supported"
  end
  
  def command_d
    puts "Not yet supported"
    #@shell_delete.ask
  end

  def command_q
    done
  end
end

module AwsClientDummyInterface
  class Metric
    class Dimension
      def initialize(name, value)
        @name = name
        @value = value
      end

      attr_reader :name, :value
    end

    def Metric.new_list(list)
      list.map {|a| Metric.new *a}
    end

    def initialize(type, resource, namespace, name)
      @namespace = namespace
      @metric_name = name
      @dimensions = [ Dimension.new(type, resource) ]
    end

    attr_reader :namespace, :metric_name, :dimensions
  end

  class Tag
    def Tag.new_hash(list)
      Hash[list.map {|a| t = Tag.new *a; [t.resource_id, t]}]
    end

    def initialize(id, name)
      @resource_id = id
      @value = name
    end

    attr_reader :resource_id, :value
  end


  METRIC_ARGUMENTS = [
    %w[InstanceId dummy-instance EC2 DummyCPUMetric],
    %w[InstanceId dummy-instance EC2 DummyMemoryMetric ],
    %w[InstanceId dummy-instance EC2 DummyDiskSpaceMetric ],
    %w[VolumeId dummy-volume EC2 DummyDiskOpsMetric ],
    %w[VolumeId dummy-volume EC2 DummyDiskSpaceMetric ],
  ]
  def retrieve_cloudwatch_metrics
    puts 'Use dummy metric list'
    Metric.new_list METRIC_ARGUMENTS
  end

  TAG_ARGUMENTS = [
    ['dummy-instance', 'dummy: ec2 instance'],
    ['dummy-volume', 'dummy: ebs volume'],
  ]
  def retrieve_ec2_tags(tags)
    puts 'Use dummy tags', tags
    Tag.new_hash TAG_ARGUMENTS
  end
end

OptionParser.new do |opts|
  opts.banner = 'Usage: example.rb [options]'

  opts.on('-d', '--dummy', 'Run with dummy data') do ||
    AwsClient.instance.extend AwsClientDummyInterface
  end
end.parse!

MainCommandShell.new.ask

