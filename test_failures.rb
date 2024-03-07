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

def extract_failures_and_details(content)
  failures = {}
  current_failure = nil
  current_details = []
  capture_details = false

  content.each_line do |line|
    line = line.sub(/^[^ ]+\s+/, '').rstrip

    if line.start_with?(/\d+\) /)
      if current_failure
        failures[current_failure][:details] ||= []
        failures[current_failure][:details] << current_details unless current_details.empty?
        current_details = []
      end
      current_failure = line.sub(/\d+\) /, '')
      failures[current_failure] ||= { count: 0, details: [] }
      capture_details = true
    elsif line.start_with?('Finished in')
      capture_details = false
    elsif capture_details
      next if unwanted_line?(line)
      current_details << line.strip
    end
  end

  if current_failure && !current_details.empty?
    failures[current_failure][:details] ||= []
    failures[current_failure][:details] << current_details
  end

  failures
end

def unwanted_line?(line)
  line.empty? ||
    line.start_with?('# ./vendor/bundle') ||
    line.start_with?('[Screenshot Image]:') ||
    line.end_with?('<unknown>')
end

def merge_similar_details(details_array)
  merged_details = []

  details_array.each do |details|
    error_message = details.reject { |line| line.start_with?('# ') }.join("\n")
    similar_details = merged_details.find { |d| d.reject { |line| line.start_with?('# ') }.join("\n") == error_message }
    merged_details << details unless similar_details
  end

  merged_details
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

# Hash to store rspec failures and their details
rspec_failures = Concurrent::Hash.new { |h, k| h[k] = { count: 0, details: [] } }

total_test_runs = 0

one_week_ago = (Time.now - 7*24*60*60).utc.strftime('%Y-%m-%d')

run_ids = client.workflow_runs(
  options[:repo],
  options[:workflow_name],
  {status: "failure", per_page: 100, created: ">=#{one_week_ago}"}
)[:workflow_runs].map(&:id)

total_test_runs = run_ids.count

pool = Concurrent::FixedThreadPool.new(1)

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
              failures = extract_failures_and_details(content)
              failures.each do |failure, details|
                rspec_failures[failure][:count] += details[:details].size
                rspec_failures[failure][:details].concat(details[:details])
              end
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

puts "Most common RSpec failures from the past week (#{total_test_runs} total workflows run):\n\n"

# Print the failures, their counts, and details with indentation using tabs
rspec_failures.sort_by { |_, details| -details[:count] }.each do |failure, details|
  puts "#{failure} (Count: #{details[:count]})\n\n"
  merged_details = merge_similar_details(details[:details])
  merged_details.each_with_index do |detail_lines, index|
    detail_lines.each_with_index do |line, idx|
      if idx.eql?(0)
        puts "\t#{index+1}) #{line}"
      else
        puts "\t\t#{line}"
      end
    end
    puts "\n"
  end
end
