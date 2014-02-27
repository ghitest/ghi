# encoding: utf-8
require 'date'
require 'erb'

module GHI
  module Formatting
    class << self
      attr_accessor :paginate
    end
    self.paginate = true # Default.

    attr_accessor :paging

    autoload :Colors, 'ghi/formatting/colors'
    include Colors

    CURSOR = {
      :up     => lambda { |n| "\e[#{n}A" },
      :column => lambda { |n| "\e[#{n}G" },
      :hide   => "\e[?25l",
      :show   => "\e[?25h"
    }

    THROBBERS = [
      %w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏),
      %w(⠋ ⠙ ⠚ ⠞ ⠖ ⠦ ⠴ ⠲ ⠳ ⠓),
      %w(⠄ ⠆ ⠇ ⠋ ⠙ ⠸ ⠰ ⠠ ⠰ ⠸ ⠙ ⠋ ⠇ ⠆ ),
      %w(⠋ ⠙ ⠚ ⠒ ⠂ ⠂ ⠒ ⠲ ⠴ ⠦ ⠖ ⠒ ⠐ ⠐ ⠒ ⠓ ⠋),
      %w(⠁ ⠉ ⠙ ⠚ ⠒ ⠂ ⠂ ⠒ ⠲ ⠴ ⠤ ⠄ ⠄ ⠤ ⠴ ⠲ ⠒ ⠂ ⠂ ⠒ ⠚ ⠙ ⠉ ⠁),
      %w(⠈ ⠉ ⠋ ⠓ ⠒ ⠐ ⠐ ⠒ ⠖ ⠦ ⠤ ⠠ ⠠ ⠤ ⠦ ⠖ ⠒ ⠐ ⠐ ⠒ ⠓ ⠋ ⠉ ⠈),
      %w(⠁ ⠁ ⠉ ⠙ ⠚ ⠒ ⠂ ⠂ ⠒ ⠲ ⠴ ⠤ ⠄ ⠄ ⠤ ⠠ ⠠ ⠤ ⠦ ⠖ ⠒ ⠐ ⠐ ⠒ ⠓ ⠋ ⠉ ⠈ ⠈ ⠉)
    ]

    def puts *strings
      strings = strings.flatten.map { |s|
        s.gsub(/(^| *)@(\w+)/) {
          if $2 == Authorization.username
            bright { fg(:yellow) { "#$1@#$2" } }
          else
            bright { "#$1@#$2" }
          end
        }
      }
      super strings
    end

    def page header = nil, throttle = 0
      if paginate?
        pager   = GHI.config('ghi.pager') || GHI.config('core.pager')
        pager ||= ENV['PAGER']
        pager ||= 'less'
        pager  += ' -EKRX -b1' if pager =~ /^less( -[EKRX]+)?$/

        if pager && !pager.empty? && pager != 'cat'
          $stdout = IO.popen pager, 'w'
        end

        puts header if header
        self.paging = true
      end

      loop do
        yield
        sleep throttle
      end
    rescue Errno::EPIPE
      exit
    ensure
      unless $stdout == STDOUT
        $stdout.close_write
        $stdout = STDOUT
        print CURSOR[:show]
        exit
      end
    end

    def paginate?
      ($stdout.tty? && $stdout == STDOUT && Formatting.paginate) || paging?
    end

    def paging?
      !!paging
    end

    def truncate string, reserved
      return string unless paginate?
      space=columns - reserved
      space=5 if space < 5
      result = string.scan(/.{0,#{space}}(?:\s|\Z)/).first.strip
      result << "..." if result != string
      result
    end

    def indent string, level = 4, maxwidth = columns
      string = string.gsub(/\r/, '')
      string.gsub!(/[\t ]+$/, '')
      string.gsub!(/\n{3,}/, "\n\n")
      width = maxwidth - level - 1
      lines = string.scan(
        /.{0,#{width}}(?:\s|\Z)|[\S]{#{width},}/ # TODO: Test long lines.
      ).map { |line| " " * level + line.chomp }
      format_markdown lines.join("\n").rstrip, level
    end

    def columns
      dimensions[1] || 80
    end

    def dimensions
      `stty size 2>/dev/null`.chomp.split(' ').map { |n| n.to_i }
    end

    #--
    # Specific formatters:
    #++

    def format_username username
      username == Authorization.username ? 'you' : username
    end

    def format_issues_header
      state = assigns[:state] ||= 'open'
      org = assigns[:org] ||= nil
      header = "# #{repo || org || 'Global,'} #{state} issues"
      if repo
        if milestone = assigns[:milestone]
          case milestone
            when '*'    then header << ' with a milestone'
            when 'none' then header << ' without a milestone'
          else
            header.sub! repo, "#{repo} milestone ##{milestone}"
          end
        end
        if assignee = assigns[:assignee]
          header << case assignee
            when '*'    then ', assigned'
            when 'none' then ', unassigned'
          else
            ", assigned to #{format_username assignee}"
          end
        end
        if mentioned = assigns[:mentioned]
          header << ", mentioning #{format_username mentioned}"
        end
      else
        header << case assigns[:filter]
          when 'created'    then ' you created'
          when 'mentioned'  then ' that mention you'
          when 'subscribed' then " you're subscribed to"
          when 'all'        then ' that you can see'
        else
          ' assigned to you'
        end
      end
      if creator = assigns[:creator]
        header << " #{format_username creator} created"
      end
      if labels = assigns[:labels]
        header << ", labeled #{labels.gsub ',', ', '}"
      end
      if excluded_labels = assigns[:exclude_labels]
        header << ", excluding those labeled #{excluded_labels.gsub ',', ', '}"
      end
      if sort = assigns[:sort]
        header << ", by #{sort} #{reverse ? 'ascending' : 'descending'}"
      end
      format_state assigns[:state], header
    end

    def format_issues issues, include_repo
      return 'None.' if issues.empty?

      include_repo and issues.each do |i|
        %r{/repos/[^/]+/([^/]+)} === i['url'] and i['repo'] = $1
      end

      nmax, rmax = %w(number repo).map { |f|
        issues.sort_by { |i| i[f].to_s.size }.last[f].to_s.size
      }

      issues.map { |i|
        n, title, labels = i['number'], i['title'], i['labels']
        l = 9 + nmax + rmax + no_color { format_labels labels }.to_s.length
        a = i['assignee']
        a_is_me = a && a['login'] == Authorization.username
        l += a['login'].to_s.length + 2 if a
        p = i['pull_request']['html_url'] and l += 2 if i['pull_request']
        c = i['comments']
        l += c.to_s.length + 1 unless c == 0
        m = i['milestone']
        [
          " ",
          (i['repo'].to_s.rjust(rmax) if i['repo']),
          format_number(n.to_s.rjust(nmax)),
          truncate(title, l),
          (format_labels(labels) unless assigns[:dont_print_labels]),
          (fg(:green) { m['title'] } if m),
          (fg('aaaaaa') { c } unless c == 0),
          (fg('aaaaaa') { '↑' } if p),
          (fg(a_is_me ? :yellow : :gray) { "@#{a['login']}" } if a),
          (fg('aaaaaa') { '‡' } if m)
        ].compact.join ' '
      }
    end

    def format_number n
      colorize? ? "#{bright { n }}:" : "#{n} "
    end

    # TODO: Show milestone, number of comments, pull request attached.
    def format_issue i, width = columns
      return unless i['created_at']
      ERB.new(<<EOF).result binding
<% p = i['pull_request']['html_url'] %>\
<%= bright { no_color { indent '%s%s: %s' % [p ? '↑' : '#', \
*i.values_at('number', 'title')], 0, width } } %>
@<%= i['user']['login'] %> opened this <%= p ? 'pull request' : 'issue' %> \
<%= format_date DateTime.parse(i['created_at']) %>. \
<% if i['merged'] %><%= format_state 'merged', format_tag('merged'), :bg %><% end %> \
<%= format_state i['state'], format_tag(i['state']), :bg %> \
<% unless i['comments'] == 0 %>\
<%= fg('aaaaaa'){
  template = "%d comment"
  template << "s" unless i['comments'] == 1
  '(' << template % i['comments'] << ')'
} %>\
<% end %>\
<% if i['assignee'] || !i['labels'].empty? %>
<% if i['assignee'] %>@<%= i['assignee']['login'] %> is assigned. <% end %>\
<% unless i['labels'].empty? %><%= format_labels(i['labels']) %><% end %>\
<% end %>\
<% if i['milestone'] %>
Milestone #<%= i['milestone']['number'] %>: <%= i['milestone']['title'] %>\
<%= " \#{bright{fg(:yellow){'⚠'}}}" if past_due? i['milestone'] %>\
<% end %>
<% if block_given? %><%= yield %><% end %>\
<% if i['body'] && !i['body'].empty? %>
<%= indent i['body'], 4, width %>
<% end %>

EOF
    end

    def format_comments_and_events elements
      return 'None.' if elements.empty?
      elements.map do |element|
        if event = element['event']
          format_event(element) unless unimportant_event?(event)
        else
          format_comment(element)
        end
      end.compact
    end

    def format_comment c, width = columns
      <<EOF
@#{c['user']['login']} commented \
#{format_date DateTime.parse(c['created_at'])}:
#{indent c['body'], 4, width}


EOF
    end

    def format_event e, width = columns
      reference = e['commit_id']
      <<EOF
#{bright { '⁕' }} #{format_event_type(e['event'])} by @#{e['actor']['login']}\
#{" through #{underline { reference[0..6] }}" if reference} \
#{format_date DateTime.parse(e['created_at'])}

EOF
    end

    def format_milestones milestones
      return 'None.' if milestones.empty?

      max = milestones.sort_by { |m|
        m['number'].to_s.size
      }.last['number'].to_s.size

      milestones.map { |m|
        line = ["  #{m['number'].to_s.rjust max }:"]
        space = past_due?(m) ? 6 : 4
        line << truncate(m['title'], max + space)
        line << '⚠' if past_due? m
        percent m, line.join(' ')
      }
    end

    def format_milestone m, width = columns
      ERB.new(<<EOF).result binding
<%= bright { no_color { \
indent '#%s: %s' % m.values_at('number', 'title'), 0, width } } %>
@<%= m['creator']['login'] %> created this milestone \
<%= format_date DateTime.parse(m['created_at']) %>. \
<%= format_state m['state'], format_tag(m['state']), :bg %>
<% if m['due_on'] %>\
<% due_on = DateTime.parse m['due_on'] %>\
<% if past_due? m %>\
<%= bright{fg(:yellow){"⚠"}} %> \
<%= bright{fg(:red){"Past due by \#{format_date due_on, false}."}} %>
<% else %>\
Due in <%= format_date due_on, false %>.
<% end %>\
<% end %>\
<%= percent m %>
<% if m['description'] && !m['description'].empty? %>
<%= indent m['description'], 4, width %>
<% end %>

EOF
    end

    def past_due? milestone
      return false unless milestone['due_on']
      DateTime.parse(milestone['due_on']) <= DateTime.now
    end

    def percent milestone, string = nil
      open, closed = milestone.values_at('open_issues', 'closed_issues')
      complete = closed.to_f / (open + closed)
      complete = 0 if complete.nan?
      i = (columns * complete).round
      if string.nil?
        string = ' %d%% (%d closed, %d open)' % [complete * 100, closed, open]
      end
      string = string.ljust columns
      [bg('2cc200'){string[0, i]}, string[i, columns - i]].join
    end

    def format_state state, string = state, layer = :fg
      color_codes = {
        'closed' => 'ff0000',
        'open'   => '2cc200',
        'merged' => '511c7d',
      }
      send(layer, color_codes[state]) { string }
    end

    def format_labels labels
      return if labels.empty?
      [*labels].map { |l| bg(l['color']) { format_tag l['name'] } }.join ' '
    end

    def format_tag tag
      (colorize? ? ' %s ' : '[%s]') % tag
    end

    def format_event_type(event)
      color_codes = {
        'reopened' => '2cc200',
        'closed' => 'ff0000',
        'merged' => '9677b1',
        'assigned' => 'e1811d',
        'referenced' => 'aaaaaa'
      }
      fg(color_codes[event]) { event }
    end

    def format_pull_info(pr, width = columns)
      "\n#{format_merge_stats(pr, 4)}#{format_pr_stats(pr, 4)}\n"
    end

    def format_pr_stats(pr, indent)
      indent = ' ' * indent
      add, del  = pr.values_at('additions', 'deletions')
      commits   = count_with_plural(pr['commits'].to_i, 'commit')
      files     = count_with_plural(pr['changed_files'].to_i, 'file') + ' changed'
      additions = fg('2cc200') { "+#{add}"}
      deletions = fg('ff0000') { "-#{del}"}

      output = [
        fg('cccc33') { "#{commits}, #{files}" },
        "#{additions} #{change_viz(add, del)} #{deletions}"
      ]

      output.map { |line| "#{indent}#{line}" }.join("\n")
    end

    def change_viz(additions, deletions, size = 18)
      sign = '∎'
      all = (additions + deletions).to_f

      # when an empty file was submitted (or a binary!) there might be
      # a total number of 0 line canges. A division of 0 / 0 throws an error,
      # therefore we just return without further operations
      return fg('aaaaaa') { sign * size } if all.zero?

      add_percent = additions / all
      del_percent = deletions / all
      rel = [add_percent, del_percent].map { |p| (p * size).round.to_i }
      rel.zip(['2cc200', 'ff0000']).map do |multiplicator, color|
        fg(color) { sign * multiplicator }
      end.join
    end

    def format_merge_stats(pr, indent)
      indent = ' ' * indent
      if date = pr['merged_at']
        merger  = pr['merged_by']['login']
        message = "merged by @#{merger} #{format_date DateTime.parse(date)}"
        "#{indent}#{message}\n\n"
      else
        str = "#{indent}#{format_merge_head_and_base(pr)}\n"
        "#{str}#{indent}#{format_mergeability}\n\n"
      end
    end

    def format_mergeability
      if clean?
        if needs_rebase?
          fg('e1811d') { "✔ able to merge, but needs a rebase" }
        else
          fg('2cc200') { "✔ able to merge" }
        end
      elsif dirty?
        fg('ff0000') { "✗ pull request is dirty" }
      end
    end

    def format_merge_head_and_base(pr)
      head, base = pr.values_at('head', 'base').map { |br| br['label'] }
      "#{fg('cccc33') { base }} ⬅ #{fg('cccc33') { head } }"
    end

    def count_with_plural(count, term)
      s = count == 1 ? '' : 's'
      "#{count} #{term}#{s}"
    end

    def format_commits(commits)
      header = format_commits_header(commits)
      body   = commits.map { |commit| format_commit(commit) }.join("\n")
      "#{header}\n\n#{body}"
    end

    def format_commits_header(commits)
      n = commits.size
      count   = count_with_plural(n, 'commit')
      authors = commits.map { |commit| commit['author']['login'] }.uniq
      authors = enumerative_concat(authors, 'and')
      fg('cccc33') { "#{count} by #{authors}" }
    end

    def enumerative_concat(arr, last_coordination)
      return arr.first if arr.one?
      "#{arr[0..-2].join(', ')} #{last_coordination} #{authors[-1]}"
    end

    def format_commit(commit, indent = 4, width = columns)
      indent = ' ' * indent
      sha   = commit['sha'][0..6]
      title = commit['commit']['message'].split("\n\n").first
      "#{indent}* #{sha} | #{truncate(title, 20)}"
    end

    def format_files(files)
      header = format_files_header(files)
      body   = files.map { |file| format_file(file) }.join("\n")
      "#{header}\n\n#{body}"
    end

    def format_files_header(files)
      add = summate_changes(files, 'additions')
      del = summate_changes(files, 'deletions')
      count   = count_with_plural(files.size, 'file')
      changes = "#{add} additions and #{del} deletions"
      fg('cccc33') { "#{count}, with #{changes}" }
    end

    def summate_changes(container, type)
      container.map { |element| element[type] }.inject(:+)
    end

    def format_file(file)
      status = {
        'added'    => fg('2cc200') { '+' },
        'modified' => fg('yellow') { '~' },
        'removed'  => fg('ff0000') { '-' },
      }
      name = sprintf("%-50s", file['filename'])
      state = status[file['status']]
      add, del, changes = file.values_at('additions', 'deletions', 'changes')
      bar = change_viz(add, del, 5)
      "#{state} #{name}#{changes} #{bar}"
    end

    def format_diff(diff)
      # FIXME: Minor inconsistencies in colored output
      diff.gsub!(/^((?:diff|index|---|\+\+\+).*)/, bright { '\1' })
      diff.gsub!(/^(@@ .* @@)/, fg('387593') { '\1' })
      diff.gsub!(/^(\+[^\+]?.*)/, fg('8abb3b') { '\1' })
      diff.gsub!(/^(-[^-]?.*)/,  fg('ff7f66') { '\1' })
      diff
    end

    #--
    # Helpers:
    #++

    #--
    # TODO: DRY up editor formatters.
    #++
    def format_editor issue = nil
      message = ERB.new(<<EOF).result binding

Please explain the issue. The first line will become the title. Trailing
markdown comments (like these) will be ignored, and empty messages will
not be submitted. Issues are formatted with GitHub Flavored Markdown (GFM):

  http://github.github.com/github-flavored-markdown

On <%= repo %>

<%= no_color { format_issue issue, columns - 2 if issue } %>
EOF
      message.rstrip!
      message.gsub!(/(?!\A)^.*$/) { |line| line.rstrip }
      max_line_len = message.gsub(/(?!\A)^.*$/).max_by(&:length).length
      message.gsub!(/(?!\A)^.*$/) { |line| "<!-- #{line.ljust(max_line_len)} -->" }
      # Adding an extra newline for formatting
      message.insert 0, "\n"
      message.insert 0, [
        issue['title'] || issue[:title], issue['body'] || issue[:body]
      ].compact.join("\n\n") if issue
      message
    end

    def format_milestone_editor milestone = nil
      message = ERB.new(<<EOF).result binding

Describe the milestone. The first line will become the title. Trailing
markdown comments (like these) will be ignored, and empty messages will not be
submitted. Milestones are formatted with GitHub Flavored Markdown (GFM):

  http://github.github.com/github-flavored-markdown

On <%= repo %>

<%= no_color { format_milestone milestone, columns - 2 } if milestone %>
EOF
      message.rstrip!
      message.gsub!(/(?!\A)^.*$/) { |line| line.rstrip }
      max_line_len = message.gsub(/(?!\A)^.*$/).max_by(&:length).length
      message.gsub!(/(?!\A)^.*$/) { |line| "<!-- #{line.ljust(max_line_len)} -->" }
      message.insert 0, [
        milestone['title'], milestone['description']
      ].join("\n\n") if milestone
      message
    end

    def format_comment_editor issue, comment = nil
      message = ERB.new(<<EOF).result binding

Leave a comment. Trailing markdown comments (like these) will be ignored,
and empty messages will not be submitted. Comments are formatted with GitHub
Flavored Markdown (GFM):

  http://github.github.com/github-flavored-markdown

On <%= repo %> issue #<%= issue['number'] %>

<%= no_color { format_issue issue } if verbose %>\
<%= no_color { format_comment comment, columns - 2 } if comment %>
EOF
      message.rstrip!
      message.gsub!(/(?!\A)^.*$/) { |line| line.rstrip }
      max_line_len = message.gsub(/(?!\A)^.*$/).max_by(&:length).length
      message.gsub!(/(?!\A)^.*$/) { |line| "<!-- #{line.ljust(max_line_len)} -->" }
      message.insert 0, comment['body'] if comment
      message
    end

    def format_markdown string, indent = 4
      c = '268bd2'

      # Headers.
      string.gsub!(/^( {#{indent}}\#{1,6} .+)$/, bright{'\1'})
      string.gsub!(
        /(^ {#{indent}}.+$\n^ {#{indent}}[-=]+$)/, bright{'\1'}
      )
      # Strong.
      string.gsub!(
        /(^|\s)(\*{2}\w(?:[^*]*\w)?\*{2})(\s|$)/m, '\1' + bright{'\2'} + '\3'
      )
      string.gsub!(
        /(^|\s)(_{2}\w(?:[^_]*\w)?_{2})(\s|$)/m, '\1' + bright {'\2'} + '\3'
      )
      # Emphasis.
      string.gsub!(
        /(^|\s)(\*\w(?:[^*]*\w)?\*)(\s|$)/m, '\1' + underline{'\2'} + '\3'
      )
      string.gsub!(
        /(^|\s)(_\w(?:[^_]*\w)?_)(\s|$)/m, '\1' + underline{'\2'} + '\3'
      )
      # Bullets/Blockquotes.
      string.gsub!(/(^ {#{indent}}(?:[*>-]|\d+\.) )/, fg(c){'\1'})
      # URIs.
      string.gsub!(
        %r{\b(<)?(https?://\S+|[^@\s]+@[^@\s]+)(>)?\b},
        fg(c){'\1' + underline{'\2'} + '\3'}
      )

      # Inline code
      string.gsub!(/`([^`].+?)`(?=[^`])/, inverse { ' \1 ' })

      # Code blocks
      string.gsub!(/(?<indent>^\ {#{indent}})(```)\s*(?<lang>\w*$)(\n)(?<code>.+?)(\n)(^\ {#{indent}}```$)/m) do |m|
        highlight(Regexp.last_match)
      end

      string
    end

    def format_date date, suffix = true
      days = (interval = DateTime.now - date).to_i.abs
      string = if days.zero?
        seconds, _ = interval.divmod Rational(1, 86400)
        hours, seconds = seconds.divmod 3600
        minutes, seconds = seconds.divmod 60
        if hours > 0
          "#{hours} hour#{'s' unless hours == 1}"
        elsif minutes > 0
          "#{minutes} minute#{'s' unless minutes == 1}"
        else
          "#{seconds} second#{'s' unless seconds == 1}"
        end
      else
        "#{days} day#{'s' unless days == 1}"
      end
      ago = interval < 0 ? 'from now' : 'ago' if suffix
      [string, ago].compact.join ' '
    end

    def throb position = 0, redraw = CURSOR[:up][1]
      return yield unless paginate?

      throb = THROBBERS[rand(THROBBERS.length)]
      throb.reverse! if rand > 0.5
      i = rand throb.length

      thread = Thread.new do
        dot = lambda do
          print "\r#{CURSOR[:column][position]}#{throb[i]}#{CURSOR[:hide]}"
          i = (i + 1) % throb.length
          sleep 0.1 and dot.call
        end
        dot.call
      end
      yield
    ensure
      if thread
        thread.kill
        puts "\r#{CURSOR[:column][position]}#{redraw}#{CURSOR[:show]}"
      end
    end

    private

    def unimportant_event?(event)
      %w{ subscribed unsubscribed mentioned }.include?(event)
    end
  end
end
