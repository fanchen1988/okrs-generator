module OKRs
  class ConfluenceWikiFormatter
    class << self
      def get_formatted_text data, is_show_all
        output_text = get_block_text(data[:past], 'Past OKRs') + "\n\n" + get_block_text(data[:next][:remaining], 'Next Remaining OKRs')
        output_text += "\n\n" + get_block_text(data[:next][:others], 'Next Other OKRs') if is_show_all
        output_text
      end

      private

      def get_block_text data, subject
        issues = data[:issues]
        pulls = data[:pulls]
        issue_lines = get_item_lines issues
        pull_lines = get_item_lines pulls
        <<~TEXT
        ===============================
        #{subject}
        --------------
        h5.Issues:

        #{issue_lines.join "\n"}

        h5.Pulls:

        #{pull_lines.join "\n"}
        ===============================
        TEXT
      end

      def get_item_lines repo_items
        repo_items.map do |repo, items|
          <<~REPO
          *#{repo}*:
          #{items.map do |i|
          "- #{i[:title]} [#{get_link_text i}|#{i[:link]}] #{get_state i}"
          end.join "\n"}
          REPO
      end

      def get_link_text item
        item[:is_pull_request] ? 'pull' : 'ticket'
      end

      def get_state item
        "(#{item[:state] == 'open' ? 'y' : '/'})"
      end
    end
  end
end
