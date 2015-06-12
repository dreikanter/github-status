require 'awesome_print'
require 'dotenv'
require 'octokit'
require 'erb'
require 'tilt'
require 'ostruct'
require 'chronic_duration'
require 'action_view'
require 'active_support/all'
require 'fileutils'

include ActionView::Helpers::DateHelper
include ActionView::Helpers::TextHelper

Dotenv.load

EST_PATTERN = /^EST\s+((\d+\s*h)?\s*(\d+\s*m)?)/i
REPO = ENV['REPO']
TEMPLATE = File.join(File.expand_path(File.dirname(__FILE__)), ENV['TEMPLATE'])
OUTPUT_FILE = File.join(ENV['OUTPUT_PATH'], "#{Time.now.strftime('%Y-%m-%d')}.html")
RECENT_DATE_THRESHOLD = 7.days.ago

Octokit.configure do |c|
  c.login = ENV['GITHUB_USER']
  c.password = ENV['GITHUB_PASSWORD']
end

Octokit.auto_paginate = true

def extract_duration(text)
  ChronicDuration.parse text.scan(EST_PATTERN).last.first
rescue
  nil
end

def verbalized_duration(seconds)
  distance_of_time_in_words(seconds).gsub(/about\s+/i, '')
end

def duration_from_comments(issue_number)
  puts "Processing comments for ##{issue_number}"
  comments = Octokit.issue_comments(REPO, issue_number)
  comments.map { |c| stamped_estimate(c[:body], c[:updated_at]) }.reject(&:nil?)
end

def stamped_estimate(text, timestamp)
  duration = extract_duration(text)
  return nil unless duration
  OpenStruct.new timestamp: timestamp,
                 duration: duration,
                 duration_in_words: verbalized_duration(duration)
end

def load_issues(options)
  puts "Loading issues: #{options.to_json}"
  process_issues Octokit.issues(REPO, **options) # [0..1]
end

def open_issues
  @open_issues ||= load_issues state: :open
end

def compare_updated_at(a, b)
  a.updated_at <=> b.updated_at
end

def compare_closed_at(a, b)
  a.closed_at <=> b.closed_at
end

def load_recently_closed_issues
  issues = load_issues(state: :closed, since: RECENT_DATE_THRESHOLD)
  issues.select { |a| a.closed_at >= RECENT_DATE_THRESHOLD }.sort { |a, b| compare_closed_at(a, b) }.reverse
end

def recently_closed_issues
  @recently_closed_issues = load_recently_closed_issues
end

def process_issues(issues)
  issues.map do |issue|
    estimates = stamped_estimate(issue[:body], issue[:updated_at])
    estimates = estimates.nil? ? [] : [estimates]
    estimates += duration_from_comments(issue.number)
    estimates.sort! { |a, b| compare_updated_at(a, b) }.reverse!

    duration = estimates.any? ? (estimates.first.duration || 0) : 0

    OpenStruct.new number: issue[:number],
                   title: issue[:title],
                   state: issue[:state],
                   created_at: issue[:created_at],
                   updated_at: issue[:updated_at],
                   closed_at: issue[:closed_at],
                   estimates: estimates,
                   url: issue[:html_url],
                   duration: duration,
                   duration_in_words: verbalized_duration(duration),
                   labels: issue[:labels]
  end
end

def repo
  @repo ||= Octokit.repo(REPO)
end

def repo_data
  {
    repo_url: repo[:html_url],
    repo_title: repo[:full_name],
    open_issues_count: repo[:open_issues_count]
  }
end

def pluralize_hours(value)
  pluralize(value / 3600, 'hour')
end

def total_duration(issues)
  issues.map(&:duration).inject(&:+)
end

def total_estimation
  total_duration open_issues
end

def total_estimation_in_words
  pluralize_hours total_estimation
end

def recently_closed_total_estimation
  total_duration recently_closed_issues
end

def recently_closed_total_estimation_in_words
  pluralize_hours recently_closed_total_estimation
end

def issues_data
  {
    open_issues: open_issues,
    total_estimation_in_words: total_estimation_in_words,
    recently_closed: recently_closed_issues,
    recently_closed_total_estimation_in_words: recently_closed_total_estimation_in_words
  }
end

def context
  OpenStruct.new repo_data.merge(issues_data)
end

puts "Repository: #{REPO}"
puts "Output file: #{OUTPUT_FILE}"
FileUtils.mkdir_p File.dirname(OUTPUT_FILE)

File.open(OUTPUT_FILE, 'w') do |file|
  file.write Tilt::ERBTemplate.new(TEMPLATE).render(context)
end
