# frozen_string_literal: true

require "net/http"
require "json"

ds = ENV["WORKATO_DS"] || "www"
HOST = "https://#{ds}.workato.com"
TOKEN = ENV["WORKATO_AUTH_TOKEN"]

def headers
  {
    "Content-Type" => "application/json",
    "Authorization" => "Bearer #{TOKEN}"
  }
end

def launch_run_request(project_id)
  uri = URI("#{HOST}/api/test_cases/run_requests")
  body = { project_id: project_id }.to_json
  response = Net::HTTP.post(uri, body, headers)
  raise "Response to Workato failed: #{response.body}" unless response.code == "200"

  result = JSON.parse(response.body)
  result.dig("data", "id")
end

def fetch_run_request(id)
  uri = URI("#{HOST}/api/test_cases/run_requests/#{id}")
  response = Net::HTTP.get_response(uri, headers)
  raise "Response to Workato failed: #{response.body}" unless response.code == "200"

  JSON.parse(response.body)
end

def launch_build_request(project_build_id, env_type)
  uri = URI("#{HOST}/api/project_builds/#{project_build_id}/deploy?environment_type=#{env_type}")

  response = Net::HTTP.post(uri, "", headers)
  raise "Response to Workato failed: #{response.body}" unless response.code == "200"

  result = JSON.parse(response.body)
  result["id"]
end

def fetch_build_request(deployment_id)
  uri = URI("#{HOST}/api/deployments/#{deployment_id}")
  response = Net::HTTP.get_response(uri, headers)
  raise "Response to Workato failed: #{response.body}" unless response.code == "200"

  JSON.parse(response.body)
end

def wait_until_request_is_completed
  details = nil

  100.times do
    details = yield
    break if details

    sleep 5
  end

  details
end

def run_test_cases(project_id)
  run_request_id = launch_run_request(project_id)
  details = wait_until_request_is_completed do
    result = fetch_run_request(run_request_id)
    result if result.dig("data", "status") == "completed"
  end

  failed_requests = details["data"]["results"].select do |result|
    result["status"] != "succeeded"
  end

  if failed_requests.any?
    puts "\n\nSome of the tests failed\n\n"
    puts failed_requests
    exit 1
  else
    puts "Tests passed successfully"
  end
end

def deploy_to_env(project_build_id, env_type)
  deployment_id = launch_build_request(project_build_id, env_type)

  details = wait_until_request_is_completed do
    result = fetch_build_request(deployment_id)
    result if result["state"] == "success"
  end
  
  if details["state"] == "success"
    puts "Deployment succeeded"
  else
    puts "Deployment failed\n\n"
    puts details
    exit 1
  end
end

project_id = nil
project_build_id = nil

$stdin.each_line do |line|
  if (m = line.match(/^project_build_id: (?<project_build_id>\d+)/))
    project_build_id = m[:project_build_id]
  end
  if (m = line.match(/^project_id: (?<project_id>\d+)/))
    project_id = m[:project_id]
  end
end

unless project_id && project_build_id
  puts "Incorrect input"
  exit(1)
end

case ARGV[0]
when "test"
  deploy_to_env(project_build_id, "test")
  run_test_cases(project_id)
when "deploy"
  deploy_to_env(project_build_id, "prod")
else
  puts "Incorrect command"
  exit(1)
end
