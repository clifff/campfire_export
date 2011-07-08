#!/usr/bin/env ruby

# Portions copyright 2011 Marc Hedlund <marc@precipice.org>.
# Adapted from https://gist.github.com/821553 and ancestors.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# campfire_export.rb -- export Campfire transcripts and uploaded files.
#
# Since Campfire (www.campfirenow.com) doesn't provide an export feature,
# this script implements one via the Campfire API.
#
# Configure the script below with your Campfire account details, or it will
# not run.

require 'rubygems'

require 'cgi'
require 'fileutils'
require 'find'
require 'httparty'
require 'nokogiri'
require 'time'
require 'yaml'

module CampfireExport
  module IO
    def api_url(path)
      "#{CampfireExport::Account.base_url}#{path}"
    end

    def get(path, params = {})
      url = api_url(path)
      response = HTTParty.get(url, :query => params, :basic_auth => 
        {:username => CampfireExport::Account.api_token, :password => 'X'})

      if response.code >= 400
        raise CampfireExport::Exception.new(url, response.message, response.code)
      end
      response
    end
    
    def zero_pad(number)
      "%02d" % number
    end

    # Requires that room and date be defined in the calling object.
    def export_dir
      "campfire/#{CampfireExport::Account.subdomain}/#{room.name}/" +
        "#{date.year}/#{zero_pad(date.mon)}/#{zero_pad(date.day)}"
    end

    # Requires that room_name and date be defined in the calling object.    
    def export_file(content, filename, mode='w')
      # Check to make sure we're writing into the target directory tree.
      true_path = File.expand_path(File.join(export_dir, filename))
      unless true_path.start_with?(File.expand_path(export_dir))
        raise CampfireExport::Exception.new("#{export_dir}/#{filename}",
          "can't export file to a directory higher than target directory " +
          "(expected: #{File.expand_path(export_dir)}, actual: #{true_path}).")
      end
      
      if File.exists?("#{export_dir}/#{filename}")
        log(:error, "#{export_dir}/#{filename} failed: file already exists.")
      else
        open("#{export_dir}/#{filename}", mode) do |file|
          begin
            file.write content
          rescue => e
            log(:error, "#{export_dir}/#{filename} failed: " +
              "#{e.backtrace.join("\n")}")
          end
        end
      end
    end
    
    def verify_export(filename, expected_size)
      full_path = "#{export_dir}/#{filename}"
      unless File.exists?(full_path)
        raise CampfireExport::Exception.new(full_path, 
          "file should have been exported but does not exist")
      end
      unless File.size(full_path) == expected_size
        raise CampfireExport::Exception.new(full_path, 
          "exported file exists but is not the right size " +
          "(expected: #{expected_size}, actual: #{File.size(full_path)})")
      end
    end
    
    def log(level, message)
      case level
      when :error
        puts "*** Error: #{message}"
        open("campfire/export_errors.txt", 'a') do |log|
          log.write "#{message}\n"
        end
      else
        print message
        STDOUT.flush
      end
    end
  end
  
  class Exception < StandardError
    attr_accessor :resource, :message, :code
    def initialize(resource, message, code=nil)
      @resource = resource
      @message = message
      @code = code
    end

    def to_s
      "<#{resource}>: #{message}" + (code ? " (#{code})" : "")
    end
  end

  class Account
    include CampfireExport::IO
    include CampfireExport::TimeZone
    
    @subdomain = ""
    @api_token = ""
    @base_url  = ""
    @timezone  = ""
    
    class << self
      attr_accessor :subdomain, :api_token, :base_url, :timezone
    end
    
    def initialize(subdomain, api_token)
      CampfireExport::Account.subdomain = subdomain
      CampfireExport::Account.api_token = api_token
      CampfireExport::Account.base_url  = "https://#{subdomain}.campfirenow.com"
      CampfireExport::Account.timezone  = parse_timezone
    end
    
    def parse_timezone
      settings_html = Nokogiri::HTML get('/account/settings').body
      selected_zone = settings_html.css('select[id="account_time_zone_id"] ' +
                                        '> option[selected="selected"]')
      find_tzinfo(selected_zone.attribute("value").text)
    end
    
    def export(start_date=nil, end_date=nil)
      begin
        doc = Nokogiri::XML get('/rooms.xml').body
        doc.css('room').each do |room_xml|
          room = CampfireExport::Room.new(room_xml)
          room.export(start_date, end_date)
        end
      rescue CampfireExport::Exception => e
        log(:error, "room list download failed: #{e}")
      end
    end
  end

  class Room
    include CampfireExport::IO
    attr_accessor :id, :name, :created_at, :last_update
    
    def initialize(room_xml)
      @id          = room_xml.css('id').text
      @name        = room_xml.css('name').text

      created_utc  = DateTime.parse(room_xml.css('created-at').text)
      @created_at  = CampfireExport::Account.timezone.utc_to_local(created_utc)

      last_message = Nokogiri::XML get("/room/#{id}/recent.xml?limit=1").body
      update_utc   = DateTime.parse(last_message.css('created-at').text)
      @last_update = CampfireExport::Account.timezone.utc_to_local(update_utc)
      
    end

    def export(start_date=nil, end_date=nil)
      # Figure out how to do the least amount of work while still conforming
      # to the requester's boundary dates.
      start_date.nil? ? date = created_at      : date = [start_date, created_at].max
      end_date.nil?   ? end_date = last_update : end_date = [end_date, last_update].min
      
      while date <= end_date
        transcript = CampfireExport::Transcript.new(self, date)
        transcript.export

        # Ensure that we stay well below the 37signals API limits.
        sleep(1.0/10.0)
        date = date.next
      end
    end
  end

  class Transcript
    include CampfireExport::IO
    attr_accessor :room, :date, :messages
    
    def initialize(room, date)
      @room     = room
      @date     = date
    end
    
    def transcript_path
      "/room/#{room.id}/transcript/#{date.year}/#{date.mon}/#{date.mday}"
    end
    
    def export
      begin
        log(:info, "#{export_dir} ... ")
        transcript_xml = Nokogiri::XML get("#{transcript_path}.xml").body
        
        @messages = transcript_xml.css('message').map do |message|
          CampfireExport::Message.new(message, room, date)
        end
        
        # Only export transcripts that contain at least one message.
        if messages.length > 0
          log(:info, "exporting transcripts\n")
          FileUtils.mkdir_p export_dir

          export_file(transcript_xml, 'transcript.xml')
          verify_export('transcript.xml', transcript_xml.to_s.length)
          
          export_plaintext
          export_html
          export_uploads
        else
          log(:info, "no messages\n")
        end
      rescue CampfireExport::Exception => e
        log(:error, "transcript export for #{export_dir} failed: #{e}")
      end
    end
      
    def export_plaintext
      begin
        plaintext = "#{CampfireExport::Account.subdomain.upcase} CAMPFIRE - "
        plaintext << "#{room.name}: " +
          "#{date.strftime('%A, %B %e, %Y').gsub('  ', ' ')}\n\n"
        messages.each {|message| plaintext << message.to_s }
        export_file(plaintext, 'transcript.txt')
        verify_export('transcript.txt', plaintext.length)
      rescue CampfireExport::Exception => e
        log(:error, "Plaintext transcript export for #{export_dir} failed: #{e}")
      end
    end
        
    def export_html
      begin
        transcript_html = get(transcript_path)
        export_file(transcript_html, 'transcript.html')
        verify_export('transcript.html', transcript_html.length)
      rescue CampfireExport::Exception => e
        log(:error, "HTML transcript export for #{export_dir} failed: #{e}")
      end
    end

    def export_uploads
      messages.each do |message|
        if message.is_upload?
          begin
            message.upload.export
          rescue CampfireExport::Exception => e
            path = "#{message.upload.export_dir}/#{message.upload.filename}"
            log(:error, "Upload export for #{path} failed: " +
              "#{e.backtrace.join("\n")}")
          end
        end
      end
    end    
  end
  
  class Message
    include CampfireExport::IO
    attr_accessor :id, :room, :body, :type, :user, :date, :timestamp, :upload

    def initialize(message, room, date)
      @id = message.css('id').text
      @room = room
      @date = date
      @body = message.css('body').text
      @type = message.css('type').text

      time = Time.parse message.css('created-at').text
      localtime = CampfireExport::Account.timezone.utc_to_local(time)
      @timestamp = localtime.strftime '%I:%M %p'

      no_user = ['TimestampMessage', 'SystemMessage', 'AdvertisementMessage']
      unless no_user.include?(@type)
        begin
          @user = username(message.css('user-id').text)
        rescue CampfireExport::Exception
          @user = "[unknown user]"
        end
      end
      
      begin
        @upload = CampfireExport::Upload.new(self) if is_upload?
      rescue e
        log(:error, "Got an exception while making an upload: #{e}")
      end
    end

    def username(user_id)
      @@usernames          ||= {}
      @@usernames[user_id] ||= begin
        doc = Nokogiri::XML get("/users/#{user_id}.xml").body
        doc.css('name').text
      end
    end

    def is_upload?
      @type == 'UploadMessage'
    end

    def indent(string, count)
      (' ' * count) + string.gsub(/(\n+)/) { $1 + (' ' * count) }
    end

    def to_s
      case type
      when 'EnterMessage'
        "[#{user} has entered the room]\n"
      when 'KickMessage', 'LeaveMessage'
        "[#{user} has left the room]\n"
      when 'TextMessage'
        "[#{user}:] #{body}\n"
      when 'UploadMessage'
        "[#{user} uploaded:] #{body}\n"
      when 'PasteMessage'
        "[#{user} pasted:]\n#{indent(body, 2)}\n"
      when 'TopicChangeMessage'
        "[#{user} changed the topic to: #{body}]\n"
      when 'ConferenceCreatedMessage'
        "[#{user} created conference: #{body}]\n"
      when 'AllowGuestsMessage'
        "[#{user} opened the room to guests]\n"
      when 'DisallowGuestsMessage'
        "[#{user} closed the room to guests]\n"
      when 'LockMessage'
        "[#{user} locked the room]\n"
      when 'UnlockMessage'
        "[#{user} unlocked the room]\n"
      when 'IdleMessage'
        "[#{user} became idle]\n"
      when 'UnidleMessage'
        "[#{user} became active]\n"
      when 'TweetMessage'
        "[#{user} tweeted:] #{body}\n"
      when 'SoundMessage'
        "[#{user} played a sound:] #{body}\n"
      when 'TimestampMessage'
        "--- #{timestamp} ---\n"
      when 'SystemMessage'
        ""
      when 'AdvertisementMessage'
        ""
      else
        log(:error, "unknown message type: #{type} - '#{body}'")
        ""
      end
    end
  end
  
  class Upload
    include CampfireExport::IO
    attr_accessor :message, :room, :date, :id, :filename, :content, :byte_size
    
    def initialize(message)
      @message = message
      @room = message.room
      @date = message.date
      @deleted = false
    end
    
    def deleted?
      @deleted
    end
    
    def upload_dir
      "uploads/#{id}"
    end
    
    def export
      begin
        log(:info, "    #{message.body} ... ")

        # Get the upload object corresponding to this message.
        upload_path = "/room/#{room.id}/messages/#{message.id}/upload.xml"
        upload = Nokogiri::XML get(upload_path).body
        
        # Get the upload itself and export it.
        @id = upload.css('id').text
        @byte_size = upload.css('byte-size').text.to_i
        @filename = upload.css('name').text
        escaped_name = CGI.escape(filename)

        content_path = "/room/#{room.id}/uploads/#{id}/#{escaped_name}"        
        @content = get(content_path).body
      
        # Write uploads to a subdirectory, using the upload ID as a directory
        # name to avoid overwriting multiple uploads of the same file within
        # the same day (for instance, if 'Picture 1.png' is uploaded twice
        # in a day, this will preserve both copies). This path pattern also
        # matches the tail of the upload path in the HTML transcript, making
        # it easier to make downloads functional from the HTML transcripts.
        FileUtils.mkdir_p "#{export_dir}/#{upload_dir}"
        export_file(content, "#{upload_dir}/#{filename}", 'wb')
        verify_export("#{upload_dir}/#{filename}", byte_size)
        log(:info, "ok\n")
      rescue CampfireExport::Exception => e
        if e.code == 404
          # If the upload 404s, that should mean it was subsequently deleted.
          @deleted = true
          log(:info, "deleted\n")
        else
          log(:error, "Got an upload error: #{e.backtrace.join("\n")}")
          raise e
        end
      rescue => e
        log(:error, "export of #{export_dir}/#{upload_dir}/#{filename} failed:\n" +
          "#{e}:\n#{e.backtrace.join("\n")}")
      end
    end
  end
end
