#!/usr/bin/env ruby

require 'octokit'
require 'optparse'

module Octokit
  class Client
    module ActionsWorkflowRuns
      def rerun_failed_jobs_workflow_run(repo, id, options = {})
        boolean_from_response :post, "#{Repository.path repo}/actions/runs/#{id}/rerun-failed-jobs", options
      end
    end
  end
end

def check_mergeable_state(client, repo, pr_number)
  pr = client.pull_request(repo, pr_number)
  if pr.mergeable_state == 'behind'
    client.update_pull_request_branch(repo, pr_number)
    sleep 30

    return false
  end

  return true
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: merge_queue.rb [options]"

  opts.on("-r", "--repo REPO", "The name of the repository") do |repo|
    options[:repo] = repo
  end

  opts.on("-p", "--pr PR1,PR2,...", Array, "The PR numbers to merge") do |pr_numbers|
    options[:pr_numbers] = pr_numbers
  end

  options[:skip_merge] = false
  opts.on("-s", "--skip-merge", "Skip merging the PRs") do
    options[:skip_merge] = true
  end
end.parse!

# Check that all required options are present
if options[:repo].nil? || options[:pr_numbers].nil?
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

# Process each PR in the merge queue
options[:pr_numbers].each do |pr_number|
  # Get the PR details
  pr = client.pull_request(options[:repo], pr_number)

  if options[:skip_merge]
    puts "INFO: No reviews required since --skip-merge was specified"
  else
    # Check if the PR has all of the required reviews
    puts "INFO: Waiting for reviews to complete for PR #{pr_number}"
    sleep 60 until !client.pull_request_reviews(options[:repo], pr_number).empty? && client.pull_request_reviews(options[:repo], pr_number).any? { |review| review.state == 'APPROVED' }
    puts "INFO: Reviews completed for PR #{pr_number}"
  end

  # Rerun failed checks up to 3 times
  checks_rerun_count = 0
  while checks_rerun_count < 3
    checks_rerun_count += 1

    # Check if the PR is mergeable
    check_mergeable_state(client, options[:repo], pr_number)

    puts "INFO: Waiting for checks to complete for PR #{pr_number}"
    # Wait for the checks to complete
    # get_branch_protection in order to get the required checks
    sleep 10 until client.check_runs_for_ref(options[:repo], client.pull_request(options[:repo], pr_number).head.sha).check_runs.all? { |check| check.status == 'completed' }
    puts "INFO: Checks completed for PR #{pr_number}"

    checks = client.check_runs_for_ref(options[:repo], client.pull_request(options[:repo], pr_number).head.sha)

    # Check if any checks have failed
    failed_checks = checks.check_runs.select { |check| check.conclusion == 'failure' }
    if failed_checks.empty?
      puts "SUCCESS: All checks passed for PR #{pr_number} after #{checks_rerun_count} attempt(s)"
      break
    end

    # Rerun the failed checks
    puts "INFO: Rerunning failed checks for PR #{pr_number} (attempt #{checks_rerun_count})"
    failed_checks.each do |check|
      workflow_run = client.repository_workflow_runs(options[:repo], check_suite_id: check.check_suite.id).workflow_runs.last
      response = client.rerun_failed_jobs_workflow_run(options[:repo], workflow_run.id)
      sleep 30
    end
  end

  if options[:skip_merge]
    puts "INFO: Skipping merge for PR #{pr_number}"
  else
    # Merge the PR using squash and merge
    begin
      client.merge_pull_request(options[:repo], pr_number, '', {commit_message: '', merge_method: 'squash'})
    rescue Octokit::UnprocessableEntity => e
      puts "ERROR: Failed to merge PR #{pr_number}: #{e.message}"
      next
    end

    puts "SUCCESS: PR #{pr_number} merged successfully"
    sleep 30 # Wait for the merge to complete before processing the next PR
  end
end
