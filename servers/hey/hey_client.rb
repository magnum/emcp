# frozen_string_literal: true

module Emcp
  module Servers
    module Hey
      class Client < CliClient
        def initialize(env: {})
          super(
            bin: ENV.fetch("HEY_BIN", "hey"),
            timeout: ENV.fetch("HEY_TIMEOUT", "60").to_i,
            max_chars: ENV.fetch("EMCP_MAX_CHARS", "100000").to_i,
            env: { "HEY_NONINTERACTIVE" => "1" }.merge(env),
          )
        end

        # Only pass listing flags the command actually accepts (hey-cli v1.4.0 .surface).
        # --limit is not universal: workflow view, search, screener, and contact list reject it.
        def command(*parts, limit: nil, fetch_all: false, page: nil, account: nil, options: {}, flags: [])
          args = []
          args.push("--account", account.to_s) if present?(account)
          args.concat(parts.map(&:to_s))
          compact_options(options).each { |flag, value| args.push(flag.to_s, value.to_s) }
          Array(flags).each { |flag| args << flag.to_s if flag }
          args.push("--page", page.to_s) if present?(page)
          if fetch_all
            args << "--all"
          elsif present?(limit)
            args.push("--limit", limit.to_i.clamp(1, 500).to_s)
          end
          args << "--json"
          args
        end

        def boxes(limit: nil, fetch_all: false, account: nil)
          command("box", "list", limit: limit, fetch_all: fetch_all, account: account)
        end

        def box(name, limit: nil, fetch_all: false, page: nil, account: nil)
          command("box", "view", name, limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def labels(limit: nil, fetch_all: false, account: nil)
          command("label", "list", limit: limit, fetch_all: fetch_all, account: account)
        end

        def label(id, limit: nil, fetch_all: false, page: nil, account: nil)
          command("label", "view", id, limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def label_add(posting_ids, to:, account: nil)
          command("label", "add", *Array(posting_ids), options: { "--to" => to }, account: account)
        end

        def label_create(name, posting_ids, account: nil)
          command("label", "create", name, *Array(posting_ids), account: account)
        end

        def label_remove(posting_ids, from:, account: nil)
          command("label", "remove", *Array(posting_ids), options: { "--from" => from }, account: account)
        end

        def collections(limit: nil, fetch_all: false, account: nil)
          command("collection", "list", limit: limit, fetch_all: fetch_all, account: account)
        end

        def collection(id, limit: nil, fetch_all: false, page: nil, account: nil)
          command("collection", "view", id, limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def collection_create(name, summary: nil, account: nil)
          command("collection", "create", name, options: { "--summary" => summary }, account: account)
        end

        def collection_update(id, name: nil, summary: nil, account: nil)
          command("collection", "update", id, options: { "--name" => name, "--summary" => summary }, account: account)
        end

        def collection_add(topic_id, to:, account: nil)
          command("collection", "add", topic_id, options: { "--to" => to }, account: account)
        end

        def collection_remove(topic_id, from:, account: nil)
          command("collection", "remove", topic_id, options: { "--from" => from }, account: account)
        end

        def set_aside(limit: nil, fetch_all: false, page: nil, account: nil)
          command("set-aside", "view", limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def set_aside_groups(account: nil)
          command("set-aside", "group", "list", account: account)
        end

        def set_aside_group(id, limit: nil, fetch_all: false, page: nil, account: nil)
          command("set-aside", "group", "view", id, limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def set_aside_group_create(posting_ids, account: nil)
          command("set-aside", "group", "create", *Array(posting_ids), account: account)
        end

        def set_aside_group_add(posting_ids, to:, account: nil)
          command("set-aside", "group", "add", *Array(posting_ids), options: { "--to" => to }, account: account)
        end

        def set_aside_group_remove(posting_ids, account: nil)
          command("set-aside", "group", "remove", *Array(posting_ids), account: account)
        end

        def set_aside_group_delete(id, account: nil)
          command("set-aside", "group", "delete", id, account: account)
        end

        def workflows(limit: nil, fetch_all: false, account: nil)
          command("workflow", "list", limit: limit, fetch_all: fetch_all, account: account)
        end

        def workflow(id, account: nil)
          command("workflow", "view", id, account: account)
        end

        def workflow_create(name, account: nil)
          command("workflow", "create", name, account: account)
        end

        def workflow_update(id, name:, account: nil)
          command("workflow", "update", id, options: { "--name" => name }, account: account)
        end

        def workflow_stage_create(workflow_id, account: nil)
          command("workflow", "stage", "create", workflow_id, account: account)
        end

        def workflow_stage_update(workflow_id, stage_id, name:, account: nil)
          command("workflow", "stage", "update", workflow_id, stage_id, options: { "--name" => name }, account: account)
        end

        def workflow_add(topic_id, to:, stage: nil, account: nil)
          command("workflow", "add", topic_id, options: { "--to" => to, "--stage" => stage }, account: account)
        end

        def workflow_move(topic_id, workflow:, to:, account: nil)
          command("workflow", "move", topic_id, options: { "--workflow" => workflow, "--to" => to }, account: account)
        end

        def workflow_remove(topic_id, from:, account: nil)
          command("workflow", "remove", topic_id, options: { "--from" => from }, account: account)
        end

        def clips(account: nil)
          command("clip", "list", account: account)
        end

        def clip_create(entry_id, content:, account: nil)
          command("clip", "create", entry_id, options: { "--content" => content }, account: account)
        end

        def clip_delete(id, account: nil)
          command("clip", "delete", id, account: account)
        end

        def snippets(account: nil)
          command("snippet", "list", account: account)
        end

        def snippet_create(name:, content: nil, content_html: nil, account: nil)
          command(
            "snippet", "create",
            options: { "--name" => name, "--content" => content, "--content-html" => content_html },
            account: account,
          )
        end

        def snippet_update(id, name: nil, content: nil, content_html: nil, account: nil)
          command(
            "snippet", "update", id,
            options: { "--name" => name, "--content" => content, "--content-html" => content_html },
            account: account,
          )
        end

        def snippet_delete(id, account: nil)
          command("snippet", "delete", id, account: account)
        end

        def search(query = nil, required: nil, any: nil, none: nil, exact: nil, from: nil, to: nil,
                   subject: nil, date: nil, inbox: nil, label: nil, attachment: nil,
                   fetch_all: false, page: nil, account: nil)
          command(
            "search", *[query].compact,
            options: {
              "--required" => required,
              "--any" => any,
              "--none" => none,
              "--exact" => exact,
              "--from" => from,
              "--to" => to,
              "--subject" => subject,
              "--date" => date,
              "--in" => inbox,
              "--label" => label,
              "--attachment" => attachment,
            },
            fetch_all: fetch_all,
            page: page,
            account: account,
          )
        end

        def search_filters(account: nil)
          command("search", "filters", account: account)
        end

        def contacts(fetch_all: false, page: nil, account: nil)
          command("contact", "list", fetch_all: fetch_all, page: page, account: account)
        end

        def contact(id, html: false, account: nil)
          command("contact", "show", id, flags: [("--html" if html)], account: account)
        end

        def contact_threads(id, limit: nil, fetch_all: false, page: nil, account: nil)
          command("contact", "threads", id, limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def contact_add(name:, email:, alias_addresses: nil, account: nil)
          command(
            "contact", "add",
            options: { "--name" => name, "--email" => email, "--alias" => alias_addresses },
            account: account,
          )
        end

        def contact_update(id, name: nil, email: nil, alias_addresses: nil, account: nil)
          command(
            "contact", "update", id,
            options: { "--name" => name, "--email" => email, "--alias" => alias_addresses },
            account: account,
          )
        end

        def contact_hide(id, account: nil) = command("contact", "hide", id, account: account)
        def contact_show_again(id, account: nil) = command("contact", "show-again", id, account: account)
        def contact_bundle(id, account: nil) = command("contact", "bundle", id, account: account)
        def contact_unbundle(id, account: nil) = command("contact", "unbundle", id, account: account)

        def contact_note_show(id, html: false, account: nil)
          command("contact", "note", "show", id, flags: [("--html" if html)], account: account)
        end

        def contact_note_set(id, note: nil, note_html: nil, account: nil)
          command(
            "contact", "note", "set", id,
            options: { "--note" => note, "--note-html" => note_html },
            account: account,
          )
        end

        def contact_note_delete(id, account: nil)
          command("contact", "note", "delete", id, account: account)
        end

        def screener(fetch_all: false, page: nil, count: false, account: nil)
          command(
            "screener", "list",
            fetch_all: fetch_all,
            page: page,
            flags: [("--count" if count)],
            account: account,
          )
        end

        def screener_history(fetch_all: false, page: nil, account: nil)
          command("screener", "history", fetch_all: fetch_all, page: page, account: account)
        end

        def screener_approve(ids, box: nil, seen: false, account: nil)
          command(
            "screener", "approve", *Array(ids),
            options: { "--box" => box },
            flags: [("--seen" if seen)],
            account: account,
          )
        end

        def screener_deny(ids, spam: false, account: nil)
          command("screener", "deny", *Array(ids), flags: [("--spam" if spam)], account: account)
        end

        def screener_clear(account: nil)
          command("screener", "clear", account: account)
        end

        def threads(topic_id, html: false, allow_partial: false, markdown: false)
          command(
            "thread", "read", topic_id,
            flags: [
              ("--html" if html),
              ("--allow-partial" if allow_partial),
              ("--markdown" if markdown),
            ],
          )
        end

        def share(topic_id) = command("share", topic_id)
        def unshare(topic_id) = command("unshare", topic_id)

        def attachments(topic_id)
          command("attachment", "list", topic_id)
        end

        def drafts(limit: nil, fetch_all: false, page: nil, account: nil)
          command("draft", "list", limit: limit, fetch_all: fetch_all, page: page, account: account)
        end

        def draft_show(id, account: nil)
          command("draft", "show", id, account: account)
        end

        def draft_edit(id, to: nil, cc: nil, bcc: nil, subject: nil, message: nil, message_html: nil, account: nil)
          command(
            "draft", "edit", id,
            options: {
              "--to" => to,
              "--cc" => cc,
              "--bcc" => bcc,
              "--subject" => subject,
              "-m" => message,
              "--message-html" => message_html,
            },
            account: account,
          )
        end

        def draft_send(id, account: nil) = command("draft", "send", id, account: account)
        def draft_delete(ids, account: nil) = command("draft", "delete", *Array(ids), account: account)

        def compose(subject: nil, message: nil, message_html: nil, to: nil, cc: nil, bcc: nil,
                    thread_id: nil, draft: false, account: nil)
          command(
            "compose",
            options: {
              "--subject" => subject,
              "-m" => message,
              "--message-html" => message_html,
              "--to" => to,
              "--cc" => cc,
              "--bcc" => bcc,
              "--thread-id" => thread_id,
            },
            flags: [("--draft" if draft)],
            account: account,
          )
        end

        def reply(topic_id, message: nil, message_html: nil, draft: false)
          command(
            "reply", topic_id,
            options: { "-m" => message, "--message-html" => message_html },
            flags: [("--draft" if draft)],
          )
        end

        def forward(topic_id, to:, message: nil, message_html: nil)
          command(
            "forward", topic_id,
            options: { "--to" => to, "-m" => message, "--message-html" => message_html },
          )
        end

        def bulk_reply_preview(posting_ids)
          command("bulk-reply", "preview", *Array(posting_ids))
        end

        def bulk_reply_send(posting_ids, message: nil, message_html: nil)
          command(
            "bulk-reply", "send", *Array(posting_ids),
            options: { "-m" => message, "--message-html" => message_html },
          )
        end

        def bulk_reply_undo(delivery_id)
          command("bulk-reply", "undo", delivery_id)
        end

        def seen(ids) = command("seen", *Array(ids))
        def unseen(ids) = command("unseen", *Array(ids))

        def move(ids, to:)
          command("move", *Array(ids), options: { "--to" => to })
        end

        def bubble_up(ids, now: false, on: nil, tomorrow: false, weekend: false, next_week: false)
          command(
            "bubble", "up", *Array(ids),
            options: { "--on" => on },
            flags: [
              ("--now" if now),
              ("--tomorrow" if tomorrow),
              ("--weekend" if weekend),
              ("--next-week" if next_week),
            ],
          )
        end

        def bubble_list = command("bubble", "list")
        def bubble_pop(ids) = command("bubble", "pop", *Array(ids))
        def trash(ids) = command("trash", *Array(ids))
        def spam(ids) = command("spam", *Array(ids))
        def ignore(ids) = command("ignore", *Array(ids))
        def stop_ignoring(ids) = command("stop-ignoring", *Array(ids))

        def accounts = command("account", "list")
        def account_use(id) = command("account", "use", id)

        def calendars = command("calendar", "list")

        def events(calendar_id: nil, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false)
          command(
            "event", "list",
            options: { "--calendar" => calendar_id, "--starts-on" => starts_on, "--ends-on" => ends_on },
            limit: limit,
            fetch_all: fetch_all,
          )
        end

        def event_day(date = nil, limit: nil, fetch_all: false)
          command("event", "day", *[date].compact, limit: limit, fetch_all: fetch_all)
        end

        def event_week(date = nil, limit: nil, fetch_all: false)
          command("event", "week", *[date].compact, limit: limit, fetch_all: fetch_all)
        end

        def event_add(title, starts_on: nil, start_time: nil, end_time: nil, calendar_id: nil,
                      repeat: nil, remind: nil, time_zone: nil)
          command(
            "event", "add", title,
            options: {
              "--starts-on" => starts_on,
              "--start-time" => start_time,
              "--end-time" => end_time,
              "--calendar" => calendar_id,
              "--repeat" => repeat,
              "--remind" => remind,
              "--time-zone" => time_zone,
            },
          )
        end

        def event_edit(id, date: nil, title: nil, starts_on: nil, start_time: nil, end_time: nil,
                       calendar_id: nil, countdown: nil)
          command(
            "event", "edit", id, *[date].compact,
            options: {
              "--title" => title,
              "--starts-on" => starts_on,
              "--start-time" => start_time,
              "--end-time" => end_time,
              "--calendar" => calendar_id,
              "--countdown" => countdown,
            },
          )
        end

        def event_delete(id) = command("event", "delete", id)

        def todos(limit: nil, fetch_all: false, starts_on: nil, ends_on: nil)
          command(
            "todo", "list",
            options: { "--starts-on" => starts_on, "--ends-on" => ends_on },
            limit: limit,
            fetch_all: fetch_all,
          )
        end

        def todo_add(title, date: nil)
          command("todo", "add", title, options: { "--date" => date })
        end

        def todo_complete(id) = command("todo", "complete", id)
        def todo_uncomplete(id) = command("todo", "uncomplete", id)
        def todo_delete(id) = command("todo", "delete", id)

        def habits(date: nil)
          command("habit", "list", options: { "--date" => date })
        end

        def habit_create(name, icon: nil, color: nil, days: nil)
          command("habit", "create", name, options: { "--icon" => icon, "--color" => color, "--days" => days })
        end

        def habit_edit(id, name: nil, icon: nil, color: nil, days: nil)
          command("habit", "edit", id, options: { "--name" => name, "--icon" => icon, "--color" => color, "--days" => days })
        end

        def habit_delete(id) = command("habit", "delete", id)
        def habit_complete(id, date: nil) = command("habit", "complete", id, options: { "--date" => date })
        def habit_uncomplete(id, date: nil) = command("habit", "uncomplete", id, options: { "--date" => date })

        def timetrack(action, category: nil)
          command("timetrack", action, options: { "--category" => category })
        end

        def timetrack_list(limit: nil, fetch_all: false, category: nil)
          command("timetrack", "list", options: { "--category" => category }, limit: limit, fetch_all: fetch_all)
        end

        def timetrack_edit(id, start: nil, finish: nil, category: nil, notes: nil)
          command(
            "timetrack", "edit", id,
            options: { "--start" => start, "--end" => finish, "--category" => category, "--notes" => notes },
          )
        end

        def timetrack_delete(id) = command("timetrack", "delete", id)
        def timetrack_categories = command("timetrack", "categories")
        def timetrack_category_create(title) = command("timetrack", "category", "create", title)
        def timetrack_category_rename(id, title) = command("timetrack", "category", "rename", id, title)
        def timetrack_category_delete(id) = command("timetrack", "category", "delete", id)

        def journal_list(limit: nil, fetch_all: false, starts_on: nil, ends_on: nil)
          command(
            "journal", "list",
            options: { "--starts-on" => starts_on, "--ends-on" => ends_on },
            limit: limit,
            fetch_all: fetch_all,
          )
        end

        def journal_read(date: nil, html: false)
          command("journal", "read", *[date].compact, flags: [("--html" if html)])
        end

        def journal_write(content, date: nil, content_html: nil)
          command(
            "journal", "write", *[date].compact,
            options: { "-c" => content, "--content-html" => content_html },
          )
        end

        def auth_status = command("auth", "status")
        def auth_token = [ "auth", "token", "--quiet" ]
        def auth_login(token) = command("auth", "login", options: { "--token" => token })
        def auth_logout = command("auth", "logout")
        def doctor = command("doctor")
        def config_show = command("config", "show")

        private

        def present?(value)
          !value.nil? && value != "" && value != false
        end

        def compact_options(options)
          options.reject { |_, value| value.nil? || value == "" }
        end
      end
    end
  end
end
