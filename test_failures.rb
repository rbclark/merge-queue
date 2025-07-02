#!/usr/bin/env ruby

require 'open-uri'
require 'zip'
require 'octokit'
require 'optparse'
require 'tempfile'

# Enable auto-pagination
Octokit.configure do |c|
  c.auto_paginate = true
end

# Silence WARNING: invalid date/time in zip entry.
Zip.warn_invalid_date = false

NETWORK_RETRIES = 3

def fetch_attempt_data(client, attempt_url)
  attempts = 0
  begin
    client.get(attempt_url)
  rescue Octokit::NotFound
    # If the attempt is not found, return nil
    puts "Attempt not found at #{attempt_url}"
    return nil
  rescue => e
    attempts += 1
    if attempts <= NETWORK_RETRIES
      sleep(2 ** attempts)
      retry
    else
      raise e
    end
  end
end

def fetch_attempt_logs(logs_url, github_token)
  attempts = 0
  begin
    # Fetch logs using the logs_url with authentication headers
    log_data = URI.open(logs_url,
                        "Authorization" => "Bearer #{github_token}",
                        "Accept" => "application/vnd.github.v3+json").read
    log_data
  rescue OpenURI::HTTPError => e
    if e.io.status[0] == '404'
      puts "Logs not found at #{logs_url}"
      return nil
    else
      attempts += 1
      if attempts <= NETWORK_RETRIES
        sleep(2 ** attempts)
        retry
      else
        puts "Error fetching logs from #{logs_url}: #{e.message}"
        return nil
      end
    end
  rescue => e
    attempts += 1
    if attempts <= NETWORK_RETRIES
      sleep(2 ** attempts)
      retry
    else
      puts "Error fetching logs from #{logs_url}: #{e.message}"
      return nil
    end
  end
end

def extract_failures_and_details(content)
  failures = {}
  current_failure = nil
  current_details = []
  capture_details = false
  in_pending_section = false

  content.each_line do |line|
    line = line.sub(/^[^ ]+\s+/, '').rstrip

    if line =~ /^Pending: \(Failures listed here are expected and do not affect your suite's status\)/
      in_pending_section = true
      next
    # This line indicates the end of the pending section and the start of actual failures
    elsif line.eql?('Failures:')
      in_pending_section = false
    # This is to avoid capturing all of the text following the failures section
    elsif line.start_with?("Finished in")
      capture_details = false
    end

    # Skip lines in the pending section
    next if in_pending_section

    if line =~ /^\d+\) /
      if current_failure
        failures[current_failure][:details] << current_details unless current_details.empty?
        current_details = []
      end
      current_failure = line.sub(/^\d+\) /, '')
      failures[current_failure] ||= { count: 0, details: [] }
      capture_details = true
    elsif capture_details
      next if unwanted_line?(line)
      current_details << line.strip
    end
  end

  if current_failure && !current_details.empty?
    failures[current_failure][:details] << current_details
  end

  failures
end

def unwanted_line?(line)
  line.empty? ||
    line.match?(/^#?\s*(?:\.\/)?vendor\/bundle/) ||
    line.match?(/^#?\s*\/opt\/hostedtoolcache\/Ruby/) ||
    line.start_with?('[Screenshot Image]:') ||
    line.end_with?('<unknown>')
end

def merge_similar_details(details_array)
  merged_details = {}

  details_array.each do |details|
    error_message = details.reject { |line| line.start_with?('# ') }.join("\n")
    if merged_details.key?(error_message)
      merged_details[error_message][:count] += 1
    else
      merged_details[error_message] = { count: 1, lines: details }
    end
  end

  merged_details.values
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: test_failures.rb [options]"
  opts.on("-r", "--repo REPO", "The name of the repository (e.g., 'owner/repo')") do |repo|
    options[:repo] = repo
  end
  opts.on("-w", "--workflow-filename WORKFLOW_FILENAME", "The filename of the workflow to analyze") do |workflow_name|
    options[:workflow_name] = workflow_name
  end
end.parse!

# Check that all required options are present
if options[:repo].nil? || options[:workflow_name].nil?
  puts "ERROR: Missing required options"
  puts
  puts OptionParser.new.help
  exit 1
end

# Retrieve the GitHub token from the environment variable
github_token = ENV['GITHUB_TOKEN']
if github_token.nil? || github_token.empty?
  puts "ERROR: The GITHUB_TOKEN environment variable is not set"
  exit 1
end

# Initialize the Octokit client with the GitHub token
client = Octokit::Client.new(access_token: github_token)

# Hash to store RSpec failures and their details
rspec_failures = Hash.new { |h, k| h[k] = { count: 0, details: [] } }

total_test_runs = 0

one_week_ago = (Time.now - 7 * 24 * 60 * 60).utc.iso8601

# Fetch all workflow runs for the specified workflow within the time frame
workflow_runs = client.workflow_runs(
  options[:repo],
  options[:workflow_name],
  { per_page: 100, created: ">=#{one_week_ago}" }
)[:workflow_runs]

workflow_runs.each do |run|
  begin
    # Collect all attempts for this run by traversing previous_attempt_url
    attempts = []
    current_attempt = run
    attempts << current_attempt

    while current_attempt[:previous_attempt_url]
      previous_attempt_url = current_attempt[:previous_attempt_url]
      current_attempt = fetch_attempt_data(client, previous_attempt_url)
      break unless current_attempt
      attempts << current_attempt
    end

    # Increment total_test_runs by the number of attempts for this run
    total_test_runs += attempts.size

    attempts.each do |attempt|
      # Fetch logs for each attempt using logs_url
      logs_url = attempt[:logs_url]
      log_data = fetch_attempt_logs(logs_url, github_token)
      # Skip if no log data was returned
      next if log_data.nil?

      Tempfile.create("log_zip") do |log_zip|
        log_zip.binmode
        log_zip.write(log_data)
        log_zip.rewind

        Zip::File.open(log_zip) do |zip_file|
          zip_file.each do |entry|
            # Only process top-level files; GitHub logs contain duplicate files within subdirectories
            if entry.file? && !entry.name.include?('/')
              content = entry.get_input_stream.read
              failures = extract_failures_and_details(content)
              failures.each do |failure, details|
                rspec_failures[failure][:count] += details[:details].size
                rspec_failures[failure][:details].concat(details[:details])
              end
            end
          end
        end
      end
    end
  rescue => e
    puts "Error occurred while processing run #{run.id}: #{e.message}"
    puts "Backtrace: #{e.backtrace.join("\n")}"
  end
end

puts "Most common RSpec failures from the past week (#{total_test_runs} total test runs including retries):\n\n"

if rspec_failures.any?
  # Print actual failures
  rspec_failures.sort_by { |_, details| -details[:count] }.each do |failure, details|
    puts "#{failure} (Count: #{details[:count]})\n\n"
    merged_details = merge_similar_details(details[:details])
    sorted_details = merged_details.sort_by { |detail| -detail[:count] }
    sorted_details.each do |detail|
      detail[:lines].each_with_index do |line, idx|
        if idx.eql?(0)
          puts "\t(#{detail[:count]} times) #{line}"
        else
          puts "\t\t#{line}"
        end
      end
      puts "\n"
    end
  end
else
  puts "No failures detected.\n\n"
end
