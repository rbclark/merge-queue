#!/usr/bin/env ruby

require 'open-uri'
require 'zip'
require 'octokit'
require 'optparse'
require 'tempfile'
require 'concurrent'

# Enable auto-pagination
Octokit.configure do |c|
  c.auto_paginate = true
end

# Regular expression to match rspec failures
RSPEC_FAILURE_REGEX = /rspec \.\/spec\/.*\/.*_spec\.rb:\d+/

NETWORK_RETRIES = 3

def fetch_with_retry(url)
  attempts = 0

  begin
    URI.open(url).read
  rescue => e
    attempts += 1
    if attempts <= NETWORK_RETRIES
      sleep(2**attempts)
      retry
    else
      raise e
    end
  end
end

def fetch_workflow_run_logs_with_retry(client, repo, run_id)
  attempts = 0

  begin
    client.workflow_run_logs(repo, run_id)
  rescue => e
    attempts += 1
    if attempts <= NETWORK_RETRIES
      sleep(2**attempts)
      retry
    else
      raise e
    end
  end
end

# Function to process log file content
def process_content(content)
  failures = []
  # Split the content into lines
  log_lines = content.split("\n")

  # Iterate over the lines in the log
  log_lines.each do |line|
    # Check if the line is an rspec failure
    if match = RSPEC_FAILURE_REGEX.match(line)
      # Add the rspec failure to the array
      failures << match[0]
    end
  end
  return failures
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: test_failures.rb [options]"

  opts.on("-r", "--repo REPO", "The name of the repository") do |repo|
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

# Array to store rspec failures
rspec_failures = Concurrent::Array.new
total_test_runs = 0

one_week_ago = (Time.now - 7*24*60*60).utc.strftime('%Y-%m-%d')

run_ids = client.workflow_runs(
  options[:repo],
  options[:workflow_name],
  {status: "failure", per_page: 100, created: ">=#{one_week_ago}"}
)[:workflow_runs].map(&:id)

total_test_runs = run_ids.count

pool = Concurrent::FixedThreadPool.new(5)

run_ids.each do |run|
  pool.post do
    begin
      log_url = fetch_workflow_run_logs_with_retry(client, options[:repo], run)
      Tempfile.create("log_zip") do |log_zip|
        log_zip.binmode
        log_zip.write(fetch_with_retry(log_url))
        log_zip.rewind

        Zip::File.open(log_zip) do |zip_file|
          zip_file.each do |entry|
            if entry.file?
              content = entry.get_input_stream.read
              rspec_failures.concat(process_content(content))
            end
          end
        end
      end
    rescue => e
      puts "Error occurred in thread: #{e.message}"
      puts "Backtrace: #{e.backtrace}"
      raise e
    end
  end
end

# Wait for all threads to finish
pool.shutdown
pool.wait_for_termination

# Count the occurrences of each failure
rspec_failure_counts = rspec_failures.each_with_object(Hash.new(0)) { |failure, counts| counts[failure] += 1 }

puts "Most common rspec failures from the past week (#{total_test_runs} total workflows run):"

# Print the rspec failures and their counts, sorted by count
rspec_failure_counts.sort_by { |_file, counts| -counts }.each do |file, counts|
  puts "#{file}: #{counts}"
end
