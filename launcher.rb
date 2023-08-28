# frozen_string_literal: true

require "net/http"
require "json"

dc = ENV["WORKATO_DC"] || "preview" # new trigger is available only on preview
HOST = "https://#{dc}.workato.com"
DEV_ENV_TOKEN = ENV["WORKATO_DEV_ENV_AUTH_TOKEN"]
TEST_ENV_TOKEN = ENV["WORKATO_TEST_ENV_AUTH_TOKEN"]
CALLBACK_WEBHOOK_URL = ENV["CALLBACK_WEBHOOK_URL"]
PR_BODY = ENV["PR_BODY"]
PR_URL = ENV["PR_URL"].to_s.gsub("api.github", "github").gsub("/repos/", "/").gsub("/pulls/", "/pull/")
PR_TITLE = ENV["PR_TITLE"]
PROJECT_BUILD_ID = PR_BODY.tr("\n", " ").match(/\bproject_build_id=(\d+)\b/)[1].to_i
FOLDER_ID = PR_BODY.tr("\n", " ").match(/\bfid=(\d+)\b/)[1].to_i

def headers(env)
  token =
    case env
    when :dev then DEV_ENV_TOKEN
    when :test then TEST_ENV_TOKEN
    else
      raise "Invalid env #{env}"
    end

  {
    "Content-Type" => "application/json",
    "Authorization" => "Bearer #{token}"
  }
end

def check_response!(response)
  host = HOST[8..-1]
  unless response.code == "200"
    send_webhook(event: "pr_build_failed")
    raise "Response to #{host} failed: #{response.body}"
  end
end

def send_webhook(payload = {})
  payload.merge!(
    pr_url: PR_URL,
    folder_id: FOLDER_ID,
    build_id: PROJECT_BUILD_ID,
    project_name: fetch_project_name,
    pr_title: PR_TITLE
  )
  headers = { "Content-Type" => "application/json" }
  Net::HTTP.post(URI(CALLBACK_WEBHOOK_URL), payload.to_json, headers)
end

def launch_run_request(project_id)
  uri = URI("#{HOST}/api/test_cases/run_requests")
  body = { project_id: project_id }.to_json
  response = Net::HTTP.post(uri, body, headers(:test))
  check_response!(response)

  result = JSON.parse(response.body)
  result.dig("data", "id")
end

def fetch_run_request(id)
  uri = URI("#{HOST}/api/test_cases/run_requests/#{id}")
  response = Net::HTTP.get_response(uri, headers(:test))
  check_response!(response)

  JSON.parse(response.body)
end

def fetch_project_name
  uri = URI("#{HOST}/api/project_builds/#{PROJECT_BUILD_ID}")

  response = Net::HTTP.get_response(uri, headers(:dev))
  check_response!(response)
  project_id_on_dev_env = JSON.parse(response.body)["project_id"]

  uri = URI("#{HOST}/api/projects")

  response = Net::HTTP.get_response(uri, headers(:dev))
  check_response!(response)
  dev_projects = JSON.parse(response.body)
  dev_projects.find do |project|
    project["id"] == Integer(project_id_on_dev_env)
  end["name"]
end

def fetch_project_id_on_test_env
  project_name = fetch_project_name

  response = Net::HTTP.get_response(URI("#{HOST}/api/projects"), headers(:test))
  check_response!(response)
  test_projects = JSON.parse(response.body)
  test_projects.find { |project| project["name"] == project_name }["id"]
end

def launch_build_request(project_build_id, env_type)
  release = PR_TITLE.split("release :").last.strip
  description = PR_BODY.split("**Visual diff").first.strip.sub("### ", "").gsub("\n\n", ". ")
  payload = {
    description: "Release #{release}. #{description}"
  }

  uri = URI("#{HOST}/api/project_builds/#{project_build_id}/deploy?environment_type=#{env_type}")

  response = Net::HTTP.post(uri, payload.to_json, headers(:dev))
  check_response!(response)

  result = JSON.parse(response.body)
  result["id"]
end

def fetch_build_request(deployment_id)
  uri = URI("#{HOST}/api/deployments/#{deployment_id}")
  response = Net::HTTP.get_response(uri, headers(:dev))
  check_response!(response)

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
  request_details = wait_until_request_is_completed do
    result = fetch_run_request(run_request_id)
    if result.dig("data", "status") == "completed"
      result
    else
      puts "Test cases are being executed..."
      nil
    end
  end
  tests = request_details["data"]["results"]

  puts "Executed test cases:"
  report_tests(tests)

  failed_tests = tests.select do |result|
    result["status"] != "succeeded"
  end

  if failed_tests.none?
    coverage = request_details.dig("data", "coverage", "value")
    puts color(:green, "All tests passed successfully with #{coverage}\% coverage.")
    send_webhook(event: "pr_build_succeeded")
  else
    puts "\n\n=================="
    puts color(:red, "Failed test cases:")
    report_tests(failed_tests)
    send_webhook(event: "pr_build_failed")
    exit 1
  end
end

def report_tests(tests)
  tests_by_recipe = tests.group_by { |t| t.dig("recipe", "name") }
  tests_by_recipe.each do |recipe_name, tests|
    puts "  #{recipe_name}"
    tests.each do |test|
      recipe_id = test.dig("recipe", "id")
      job_id = test.dig("job", "id")
      link = "#{HOST}/recipes/#{recipe_id}/job/#{job_id}"
      puts "    #{test.dig('test_case', 'name')}: #{format_test_status(test)}. Link: #{link}"
    end
  end
end

def format_test_status(test)
  if test["status"] == "succeeded"
    color(:green, "PASS")
  else
    color(:red, "FAIL")
  end
end

def color(color, string)
  colors = { red: 31, green: 32, blue: 34 }
  "\033[#{colors.fetch(color)}m#{string}\033[0m"
end

def deploy_to_env(project_build_id, env_type)
  deployment_id = launch_build_request(project_build_id, env_type)

  details = wait_until_request_is_completed do
    result = fetch_build_request(deployment_id)
    if result["state"] == "success"
      result
    else
      puts "The package is being deployed..."
      nil
    end
  end
  
  if details["state"] == "success"
    puts color(:green, "Deployment succeeded")
  else
    puts color(:red, "Deployment failed\n\n")
    puts details
    exit 1
  end
end

### Start of the script

if PROJECT_BUILD_ID == 0
  puts color(:red, "Incorrect input: project_build_id is required")
  send_webhook(event: "pr_build_failed")
  exit(1)
end

case ARGV[0]
when "test_package"
  deploy_to_env(PROJECT_BUILD_ID, "test")
  project_id = fetch_project_id_on_test_env
  run_test_cases(project_id)
when "deploy_to_production"
  send_webhook(event: "pr_merged")
  deploy_to_env(PROJECT_BUILD_ID, "prod")
  send_webhook(event: "pr_deployment_succeeded")
when "notify_review_requested"
  send_webhook(event: "reviewer_assigned", author: ENV["AUTHOR"], reviewer: ENV["REVIEWER"])
when "notify_pr_approved"
  send_webhook(event: "pr_approved", author: ENV["AUTHOR"], reviewer: ENV["REVIEWER"])
else
  puts color(:red, "Incorrect command. 'test', 'deploy', 'notify_review_requested', 'notify_pr_approved' are supported")
  exit(1)
end
