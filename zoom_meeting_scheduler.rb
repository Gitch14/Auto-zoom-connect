require 'open3'
require 'time'
require 'json'


ONE_HOUR_AND_20_MINUTES = 60 * 60 + 20 * 60 # const for check try to connect or no

# read data from JSON file
file_path = 'res/schedule.json'
json_data = File.read(file_path)
meeting_schedule = JSON.parse(json_data, symbolize_names: true)[:schedule]

# reformat data from json to list
schedule_list = []
meeting_schedule.each do |day, times|
  times.each do |time, link|
    schedule_list << {
      day: day.capitalize,
      time: time,
      link: link
    }
  end
end


def check_time(current_time, desired_time)
  (current_time - desired_time).abs < ONE_HOUR_AND_20_MINUTES
end

puts "Start process to open zoom"

system("res/AutoIt3/AutoIt3.exe res/open-zoom.au3")

puts "Finished process to open zoom"


loop do
  current_time = Time.now
  current_day = current_time.strftime("%A").downcase.to_sym

  # check day of week
  if meeting_schedule.key?(current_day)
    meeting_times = meeting_schedule[current_day]

    # find all time and links
    meeting_times.each do |time, link|
      desired_time = Time.parse("#{current_day.to_s.capitalize} #{time}")

      # Check equals meeting_schedule and real time
      if check_time(current_time, desired_time)
        desired_time
        meeting_id = link.match(/j\/(\d+)\?/)[1] # take link
        password = link.match(/j\/(\d+)\?pwd=(\w+)/)[2] # take pass


        puts "Start process to enter meeting zoom"

        system("res/AutoIt3/AutoIt3.exe res/autoIt3_script1.au3 #{meeting_id} #{password}") # script to open zoom conf

        puts "Zoom - connected time = " + current_time.to_s

        sleep(10)

        meeting_times.delete(time)# delete zoom conf for not repeat connection

        break
      else
        # If total lesson not start, loop do sleep 1 minute and go repeat check meeting_schedule
          sleep(30)
        end
      end
    end
  end
