module OKRs
  class GithubResourceFetcher
    DEFAULT_ORG_FACTUAL = 'Factual'

    def initialize org = DEFAULT_ORG_FACTUAL
      @client = Octokit::Client.new :netrc => true
      @client.auto_paginate = true
      @user = @client.login
      @org = org
    end

    def get_current_user
      parse_github_resource @client.user
    end

    def get_single_issue repo_name, number
      parse_github_resource @client.issue repo_name, number
    end

    def get_user_events from_time
      @client.user_events(@user)
        .reject{|event| event.created_at < from_time}
        .map &method(:parse_github_resource)
    end

    def get_all_issues_since_time from_time
      from_time = from_time.iso8601
      get_opts = lambda {|filter| {:filter => filter, :state => 'all', :sort => 'updated',
                                   :direction => 'desc', :since => from_time}}
      assigned_issues = @client.org_issues @org, get_opts.call('assigned')
      created_issues = @client.org_issues @org, get_opts.call('created')
      mentioned_issues = @client.org_issues @org, get_opts.call('mentioned')
      assigned_issues.concat(assigned_issues).concat(created_issues).concat(mentioned_issues)
        .uniq{|issue| issue['id']}
        .map &method(:parse_github_resource)
    end

    def get_opened_grouped_issues
      get_opts = lambda {|filter| {:filter => filter, :state => 'open',
                                   :sort => 'updated', :direction => 'desc'}}
      assigned_issues = @client.org_issues @org, get_opts.call('assigned')
      created_issues = @client.org_issues @org, get_opts.call('created')
      mentioned_issues = @client.org_issues @org, get_opts.call('mentioned')
      {
        :assigned => assigned_issues.map(&method(:parse_github_resource)),
        :created => created_issues.map(&method(:parse_github_resource)),
        :mentioned => mentioned_issues.map(&method(:parse_github_resource))
      }
    end

    private
    
    def parse_github_resource resource
      case resource
      when Sawyer::Resource
        resource.reduce({}) do |reduced, k_v|
          k, v = k_v
          reduced[k] = parse_github_resource v
          reduced
        end
      when Array
        resource.map &method(:parse_github_resource)
      else
        resource
      end
    end
  end
end
