# frozen_string_literal: true

require "net/http"
require "json"

dc = ENV["WORKATO_DC"] || "preview" # new trigger is available only on preview
HOST = "https://#{dc}.workato.com"
DEV_ENV_TOKEN = ENV["WORKATO_DEV_ENV_AUTH_TOKEN"]
TEST_ENV_TOKEN = ENV["WORKATO_TEST_ENV_AUTH_TOKEN"]

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
  raise "Response to #{host} failed: #{response.body}" unless response.code == "200"
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

def launch_build_request(project_build_id, env_type)
  uri = URI("#{HOST}/api/project_builds/#{project_build_id}/deploy?environment_type=#{env_type}")

  response = Net::HTTP.post(uri, "", headers(:dev))
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
  tests = wait_until_request_is_completed do
    result = fetch_run_request(run_request_id)
    if result.dig("data", "status") == "completed"
      result
    else
      puts "Test cases are being executed..."
      nil
    end
  end

  puts "Executed test cases:"
  report_tests(tests)

  failed_tests = tests["data"]["results"].select do |result|
    result["status"] != "succeeded"
  end

  if failed_tests.none?
    puts color(:green, "All tests passed successfully.")
  else
    puts "\n\n=================="
    puts color(:red, "Failed test cases:")
    report_tests(failed_tests)
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
    result if result["state"] == "success"
  end
  
  if details["state"] == "success"
    puts color(:green, "Deployment succeeded")
  else
    puts color(:red, "Deployment failed\n\n")
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

case ARGV[0]
when "test"
  unless project_id && project_build_id
    puts color(:red, "Incorrect input: project_id and project_build_id are required")
    exit(1)
  end

  # deploy_to_env(project_build_id, "test")
  run_test_cases(project_id)
when "deploy"
  unless project_build_id
    puts color(:red, "Incorrect input: project_build_id is required")
    exit(1)
  end

  deploy_to_env(project_build_id, "prod")
else
  puts color(:red, "Incorrect command. 'test' and 'deploy' are supported")
  exit(1)
end
