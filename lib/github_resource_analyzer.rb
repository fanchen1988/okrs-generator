module OKRs
  class GithubResourceAnalyzer
    EVENT_TYPES = {
      :push => 'PushEvent',
      :issue_comment => 'IssueCommentEvent',
      :issues => 'IssuesEvent',
      :pull_request_review_comment => 'PullRequestReviewCommentEvent',
      :create => 'CreateEvent'
    }
    COMMIT_MSG_ISSUE_NUMBER_PATTERN =
      /(?:for|close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+(?:Factual\/([^\s\/\\]+))?#(\d+)/i

    def initialize user_events, all_issues_since_time, opened_grouped_issues, github_fetcher
      @grouped_user_events = self.class.group_events user_events
      @grouped_all_issues_since_time = self.class.group_issues all_issues_since_time
      @grouped_opened_issues = self.class.group_opened_issues opened_grouped_issues
      @github_fetcher = github_fetcher
    end

    def get_grouped_items
      @marked_ids = Set.new
      past_items = group_past_items
      {:past => past_items, :next => group_next_items(past_items)}
    end

    private

    def group_past_items
      commented_issue_items = get_issue_related_items @grouped_user_events[:issue_comment]

      other_issue_items = get_issue_related_items @grouped_user_events[:issues]

      commented_pull_items = get_issue_related_items @grouped_user_events[:pull_request_review_comment]

      temp = get_commit_related_items @grouped_user_events[:push]
      commit_attached_items = temp[:items]
      issue_lost_commit_repos = temp[:issue_lost_commit_repos]

      past_issues = {}
      past_pulls = {}
      [commented_issue_items, other_issue_items, commit_attached_items, commented_pull_items].each do |items|
        items.each do |item|
          temp = item[:is_pull_request] ? past_pulls : past_issues
          repo_name = item[:repo_name]
          temp[repo_name] ||= []
          temp[repo_name].push item
        end
      end

      {:issues => past_issues, :pulls => past_pulls}
    end

    def group_next_items past_items
      still_open_issues = past_items[:issues].reduce({}) do |reduced, repo_issues|
        repo, issues = repo_issues
        issues = issues.select{|i|i[:state] == 'open'}
        reduced[repo] = issues unless issues.empty?
        reduced
      end
      still_open_pulls = past_items[:pulls].reduce({}) do |reduced, repo_pulls|
        repo, pulls = repo_pulls
        pulls = pulls.select{|i|i[:state] == 'open'}
        reduced[repo] = pulls unless pulls.empty?
        reduced
      end
      assigned_issues = @grouped_opened_issues[:assigned].reject{|i| @marked_ids.include? i[:id]}
      other_assigned_open_issues = {}
      other_assigned_open_pulls = {}
      assigned_issues.each do |issue|
        id = issue[:id]
        repo_name = issue[:repo_name]
        number = issue[:number]
        title = issue[:title]
        state = issue[:state]
        is_pull_request = issue[:is_pull_request]
        link = issue[:link]
        temp = is_pull_request ? other_assigned_open_pulls : other_assigned_open_issues
        temp[repo_name] ||= []
        temp[repo_name].push({
          :id => id, :repo_name => repo_name, :number => number, :title => title,
          :state => state, :is_pull_request => is_pull_request, :link => link})
      end
      {
        :remaining => {:issues => still_open_issues, :pulls => still_open_pulls},
        :others => {:issues => other_assigned_open_issues, :pulls => other_assigned_open_pulls}
      }
    end

    def get_issue_related_items issue_infos
      return [] if issue_infos.nil?
      issue_infos.reject{|id,_info|@marked_ids.include? id}.map do |id, info|
        repo_name = info[:repo_name]
        number = info[:number]
        title = info[:title]
        issue_meta = get_issue_by_id id, repo_name, number
        state = issue_meta[:state]
        is_pull_request = issue_meta[:is_pull_request]
        link = issue_meta[:link]
        @marked_ids.add id
        {
          :id => id, :repo_name => repo_name, :number => number, :title => title,
          :state => state, :is_pull_request => is_pull_request, :link => link
        }
      end.sort{|x,y|x[:id] <=> y[:id]}
    end

    def get_commit_related_items commit_infos
      issue_lost_commit_repos = []
      commit_related_items = []

      commit_infos.reject{|id,_info|@marked_ids.include? id}.each do |id, info|
        repo_name = info[:repo_name]
        number = info[:number]
        @marked_ids.add id
        if number.nil?
          issue_lost_commit_repos.push repo_name
        else
          issue_meta = get_issue_by_id id, repo_name, number
          title = info[:title]
          state = issue_meta[:state]
          is_pull_request = issue_meta[:is_pull_request]
          link = issue_meta[:link]
          commit_related_items.push({
            :id => id, :repo_name => repo_name, :number => number, :title => title,
            :state => state, :is_pull_request => is_pull_request, :link => link
          })
        end
      end
      commit_related_items = commit_related_items.sort{|x,y|x[:id] <=> y[:id]}
      issue_lost_commit_repos = issue_lost_commit_repos.sort{|x,y|x<=>y}
      {:items => commit_related_items, :issue_lost_commit_repos => issue_lost_commit_repos}
    end

    def get_issue_by_id id, repo_name, issue_number
      return @grouped_all_issues_since_time[id] if @grouped_all_issues_since_time[id]
      issue_meta = fetch_issue_meta repo_name, issue_number
      @grouped_all_issues_since_time[issue_meta[:id]] = issue_meta
      issue_meta
    end

    def fetch_issue_meta repo_name, issue_number
      issue_info = @github_fetcher.get_single_issue repo_name, issue_number
      self.class.get_issue_meta issue_info
    end

    class << self
      def group_issues issues
        issues.reduce({}) do |reduced, issue|
          get_issue_meta(issue){|id, meta|reduced[id] = meta}
          reduced
        end
      end

      def group_opened_issues opened_issues
        ids = Set.new
        [:assigned, :mentioned, :created].reduce({}) do |reduced, key|
          reduced[key] ||= []
          opened_issues[key].reduce(reduced) do |r, i|
            r[key].push(i) if ids.add? i[:id]
            r
          end
        end.reduce({}) do |reduced, key_issues|
          key, issues = key_issues
          reduced[key] = issues.map{|i| get_issue_meta i}
          reduced
        end
      end

      def get_issue_meta issue, &blk
        repo_name = issue[:repository][:full_name]
        issue_number = issue[:number]
        id = get_issue_id repo_name, issue_number
        meta = {
          #:id => issue[:id],
          :id => id,
          :title => issue[:title],
          :number => issue_number,
          :state => issue[:state],
          :repo_name => repo_name,
          :is_pull_request => (not issue[:pull_request].nil?),
          :link => issue[:html_url]
        }
        yield id, meta if block_given?
        meta
      end

      def group_events events
        events.reduce({}) do |reduced, e|
          case e[:type]
          when EVENT_TYPES[:push]
            simplified_push = simplify_push_event e
            reduced[:push] ||= {}
            reduced[:push].merge!(simplified_push) do |id, o_v, n_v|
              o_v[:events] = o_v[:events].concat n_v[:events]
              o_v
            end
          when EVENT_TYPES[:issue_comment], EVENT_TYPES[:issues], EVENT_TYPES[:pull_request_review_comment]
            case e[:type]
            when EVENT_TYPES[:issue_comment]
              key = :issue_comment
              issue_symbol = :issue
            when EVENT_TYPES[:issues]
              key = :issues
              issue_symbol = :issue
            else :pull_request_review_comment
              key = :pull_request_review_comment
              issue_symbol = :pull_request
            end
            reduced[key] ||= {}
            simplify_issue_related_event(e, issue_symbol) do |issue_id, repo_name, issue_number, title, action, updated_at|
              reduced[key][issue_id] ||= {
                :repo_name => repo_name, :number => issue_number, :title => title, :events => []
              }
              reduced[key][issue_id][:events].push({:action => action, :updated_at => updated_at})
            end
          when EVENT_TYPES[:create]
            warn "Omit for #{e[:type]}"
          else
            raise "Unsupported event type #{e[:type]}"
          end
          reduced
        end
      end

      def simplify_push_event event
        payload = event[:payload]
        return {} if payload[:distinct_size].zero?
        current_repo_name = event[:repo][:name]
        payload[:commits].select{|c|c[:distinct]}.reduce({}) do |reduced, commit_info|
          repo_name = current_repo_name
          issue_number = nil
          sha = commit_info[:sha]
          msg = commit_info[:message]
          match = msg.match COMMIT_MSG_ISSUE_NUMBER_PATTERN
          unless match.nil?
            repo_name = "Factual/#{match[1]}" unless match[1].nil?
            issue_number = match[2].to_i
          end
          id = get_issue_id repo_name, issue_number
          reduced[id] ||= {:id => id, :repo_name => repo_name, :number => issue_number, :events => []}
          reduced[id][:events].push({:sha => sha, :message => msg})
          reduced
        end
      end

      def simplify_issue_related_event event, issue_symbol, &blk
        repo_name = event[:repo][:name]
        payload = event[:payload]
        action = payload[:action]
        #id = payload[issue_symbol][:id]
        title = payload[issue_symbol][:title]
        issue_number = payload[issue_symbol][:number]
        updated_at = payload[issue_symbol][:updated_at]
        id = get_issue_id repo_name, issue_number
        yield id, repo_name, issue_number, title, action, updated_at if block_given?
        {
          id => {
            :repo_name => repo_name,
            :number => issue_number,
            :title => title,
            :events => [{:action => action, :updated_at => updated_at}]
          }
        }
      end

      def get_issue_id repo_name, issue_number
        "#{repo_name.downcase}##{issue_number}"
      end
    end
  end
end
