# frozen_string_literal: true

require "cgi"
require_relative "hey_client"

module Emcp
  module Servers
    module Hey
      class Server < ::McpServer
        server_id "hey"
        display_name "HEY"
        description "Email, calendar, todos, habits, time tracking, and journal via the official HEY CLI."
        version "0.3.0"

        LIMIT_PROPERTIES = {
          limit: { type: "integer", description: "Maximum number of items (only where hey-cli accepts --limit)" },
          fetch_all: { type: "boolean", description: "Fetch all pages instead of applying limit" },
        }.freeze
        CURSOR_PROPERTIES = {
          page: { type: "string", description: "Opaque next_page cursor from a previous listing" },
          fetch_all: { type: "boolean", description: "Follow HEY's cursor to the end (--all)" },
        }.freeze
        PAGE_PROPERTIES = {
          **CURSOR_PROPERTIES,
          limit: LIMIT_PROPERTIES[:limit],
        }.freeze
        ACCOUNT_PROPERTIES = {
          account: { type: "string", description: "Linked mail account ID, or all" },
        }.freeze
        HEY_BULLET_LINE = /\A[[:blank:]]*[-–—*•][[:blank:]]+(.+?)\z/
        HEY_NUMBERED_LINE = /\A[[:blank:]]*\d+[.)][[:blank:]]+(.+?)\z/
        HEY_PARAGRAPH_SPACER = "<div><br></div>"

        def instructions
          "Use HEY tools to read and manage email and personal productivity data. " \
            "Call hey_skill before complex workflows. " \
            "Use posting id for seen/move/label/trash and topic_id for thread read/reply/forward/share. " \
            "For hey_compose / hey_reply prefer the paragraphs array (Markdown, one idea per item). " \
            "The HEY CLI converts Markdown to rich text; use message_html only for raw HTML. " \
            "Write tools are disabled unless allow_write_methods is enabled."
        end

        def auth_help_content
          {
            title: "Get a HEY token",
            description: "Authenticate the HEY CLI on a trusted computer, then paste the token below.",
            steps: [
              "Sign in with the HEY CLI.",
              "Print the token without extra formatting.",
            ],
            commands: [
              { label: "Sign in", value: "hey auth login" },
              { label: "Copy the token", value: "hey auth token --quiet" },
            ],
            note: "Treat the token as a password and paste it only over HTTPS.",
          }
        end

        def auth_fields
          [{
            name: "hey_token",
            label: "HEY token",
            type: "password",
            required: false,
            help: "Paste the output of: hey auth token --quiet",
            value: -> { current_hey_token },
          }]
        end

        def fetch_auth_status
          raw = @client.run(@client.auth_status, truncate: false)
          data = JSON.parse(raw)
          data = data["data"] || data
          { authenticated: data["authenticated"] == true, source: data["source"] }
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def apply_credentials(params)
          token = params["hey_token"].to_s.strip
          @client.run(@client.auth_login(token), truncate: false) unless token.empty?
          invalidate_auth_status!
          raise "HEY CLI is not authenticated" unless auth_status(force: true)[:authenticated]

          true
        ensure
          token = nil
        end

        def clear_credentials!
          @client.run(@client.auth_logout, truncate: false)
          invalidate_auth_status!
        rescue CliError
          invalidate_auth_status!
          nil
        end

        def configure_tools
          define_skill
          define_auth_tools
          define_mail_read_tools
          define_contact_tools
          define_calendar_read_tools
          define_write_mail_tools
          define_write_org_tools
          define_write_calendar_tools
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = []

        # Kept for as_html / raw HTML paths. Default compose/reply now send Markdown.
        def format_hey_email_body(message: nil, paragraphs: nil)
          parts = hey_email_paragraphs(message: message, paragraphs: paragraphs)
          return "" if parts.empty?

          joined = parts.join("\n\n")
          return joined if hey_html_body?(joined)

          hey_plain_parts_to_html(parts)
        end

        private

        def hey_email_paragraphs(message: nil, paragraphs: nil)
          if paragraphs.is_a?(Array) && !paragraphs.empty?
            return paragraphs.map { |part| normalize_hey_newlines(part.to_s).strip }.reject(&:empty?)
          end

          text = normalize_hey_newlines(message.to_s).strip
          return [] if text.empty?
          return [text] if hey_html_body?(text)

          chunks = text.split(/\n[[:blank:]]*\n+/).map(&:strip).reject(&:empty?)
          chunks.empty? ? [text] : chunks
        end

        def hey_markdown_body(message: nil, paragraphs: nil)
          hey_email_paragraphs(message: message, paragraphs: paragraphs).join("\n\n")
        end

        def hey_write_payload(message: nil, paragraphs: nil, message_html: nil, as_html: false)
          if message_html.to_s.strip.present?
            return { message_html: message_html.to_s }
          end

          if as_html
            html = format_hey_email_body(message: message, paragraphs: paragraphs)
            return html.empty? ? {} : { message_html: html }
          end

          text = hey_markdown_body(message: message, paragraphs: paragraphs)
          return {} if text.empty?
          return { message_html: text } if hey_html_body?(text)

          { message: text }
        end

        def hey_plain_parts_to_html(parts)
          hey_coalesce_list_parts(parts).map { |part| hey_render_block(part) }.join(HEY_PARAGRAPH_SPACER)
        end

        def hey_coalesce_list_parts(parts)
          parts.each_with_object([]) do |part, coalesced|
            if coalesced.any? &&
               (kind = hey_list_only_kind(coalesced.last)) &&
               kind == hey_list_only_kind(part)
              coalesced[-1] = "#{coalesced.last}\n#{part}"
            else
              coalesced << part
            end
          end
        end

        def hey_list_only_kind(block)
          lines = block.to_s.split("\n").map(&:rstrip).reject(&:empty?)
          return nil if lines.empty?

          kinds = lines.map { |line| hey_list_item(line)&.first }
          return nil unless kinds.all? && kinds.uniq.size == 1

          kinds.first
        end

        def hey_render_block(block)
          lines = block.to_s.split("\n").map(&:rstrip)
          html = +""
          text_lines = []
          list_kind = nil
          list_items = []

          flush_text = lambda do
            next if text_lines.empty?

            html << "<div>#{hey_escape_with_breaks(text_lines.join("\n"))}</div>"
            text_lines = []
          end

          flush_list = lambda do
            next if list_items.empty?

            tag = list_kind == :ol ? "ol" : "ul"
            items = list_items.map { |item| "<li>#{CGI.escapeHTML(item)}</li>" }.join
            html << "<#{tag}>#{items}</#{tag}>"
            list_items = []
            list_kind = nil
          end

          lines.each do |line|
            kind, content = hey_list_item(line)
            if kind
              flush_text.call
              if list_kind && list_kind != kind
                flush_list.call
              end
              list_kind = kind
              list_items << content
            else
              flush_list.call
              text_lines << line
            end
          end
          flush_text.call
          flush_list.call
          html
        end

        def hey_list_item(line)
          if (match = line.match(HEY_BULLET_LINE))
            [:ul, match[1].strip]
          elsif (match = line.match(HEY_NUMBERED_LINE))
            [:ol, match[1].strip]
          end
        end

        def normalize_hey_newlines(text)
          cleaned = text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
          cleaned = cleaned.gsub("\\n", "\n") if !cleaned.include?("\n") && cleaned.include?("\\n")
          cleaned
        end

        def hey_html_body?(text)
          text.match?(/\A\s*</)
        end

        def hey_escape_with_breaks(text)
          CGI.escapeHTML(text.to_s).gsub("\n", "<br>")
        end

        def current_hey_token
          return "" unless auth_status[:authenticated]

          @client.run(@client.auth_token, truncate: false).to_s.strip
        rescue StandardError
          ""
        end

        def run(argv)
          cli_response(@client, argv)
        end

        def posting_ids_prop = array_prop("Box item IDs (id from box/label/search listings, not topic_id)")
        def topic_id_prop = string_prop("Thread topic_id (not the box item id)")
        def body_properties
          {
            paragraphs: array_prop("Preferred body: one Markdown paragraph or list item per element"),
            message: string_prop("Markdown body as a single string; prefer paragraphs for multi-paragraph mail"),
            message_html: string_prop("Raw HTML body; mutually exclusive with message/paragraphs"),
            as_html: boolean_prop("Convert paragraphs/message to HEY HTML instead of sending Markdown"),
          }
        end

        def define_skill
          path = File.join(__dir__, "skills", "hey", "SKILL.md")
          define_resource(
            uri: "hey://skill",
            name: "hey_skill",
            description: "Official HEY CLI agent skill.",
            mime_type: "text/markdown",
          ) { File.read(path) }
          define_tool(
            name: "hey_skill",
            description: "Return the official HEY CLI workflows, ID rules, and command reference.",
          ) { text_response(File.read(path)) }
        end

        def define_auth_tools
          define_tool(name: "hey_auth_status", description: "Show HEY CLI authentication status.") do
            run(@client.auth_status)
          end
          define_tool(
            name: "hey_auth_token",
            description: "Print the HEY CLI access token. Sensitive; use only when explicitly needed.",
          ) { run(@client.auth_token) }
          define_tool(name: "hey_config_show", description: "Show HEY CLI configuration.") do
            run(@client.config_show)
          end
          define_tool(name: "hey_accounts", description: "List linked HEY mail accounts.") do
            run(@client.accounts)
          end
          define_tool(
            name: "hey_account_senders",
            description: "List configured sender IDs and addresses. Use with from on compose or draft edit.",
            properties: { **ACCOUNT_PROPERTIES },
          ) { |account: nil| run(@client.account_senders(account: account)) }
          define_tool(
            name: "hey_account_use",
            description: "Persist the default linked mail account (id or all).",
            properties: { account: string_prop("Account ID or all") },
            required: ["account"],
            write: true,
          ) { |account:| run(@client.account_use(account)) }
          define_tool(name: "hey_doctor", description: "Run HEY CLI diagnostics.") { run(@client.doctor) }
        end

        def define_mail_read_tools
          define_tool(
            name: "hey_boxes",
            description: "List HEY mailboxes via `hey box list`.",
            properties: { **ACCOUNT_PROPERTIES, **LIMIT_PROPERTIES },
          ) { |account: nil, limit: nil, fetch_all: false| run(@client.boxes(limit: limit, fetch_all: fetch_all, account: account)) }

          define_tool(
            name: "hey_box",
            description: "List threads in a HEY box via `hey box view`. Use id for seen/move; topic_id for read/reply.",
            properties: {
              box: string_prop("Box name or ID (imbox, feedbox, trailbox, asidebox, laterbox, bubblebox)"),
              **ACCOUNT_PROPERTIES,
              **PAGE_PROPERTIES,
            },
            required: ["box"],
          ) do |box:, account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.box(box, limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_labels",
            description: "List HEY labels and their IDs.",
            properties: { **ACCOUNT_PROPERTIES, **LIMIT_PROPERTIES },
          ) { |account: nil, limit: nil, fetch_all: false| run(@client.labels(limit: limit, fetch_all: fetch_all, account: account)) }

          define_tool(
            name: "hey_label",
            description: "List threads with a HEY label.",
            properties: { label_id: string_prop("Label ID"), **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
            required: ["label_id"],
          ) do |label_id:, account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.label(label_id, limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_collections",
            description: "List HEY collections.",
            properties: { **ACCOUNT_PROPERTIES, **LIMIT_PROPERTIES },
          ) { |account: nil, limit: nil, fetch_all: false| run(@client.collections(limit: limit, fetch_all: fetch_all, account: account)) }

          define_tool(
            name: "hey_collection",
            description: "List threads in a HEY collection. Membership uses topic_id.",
            properties: { collection_id: string_prop("Collection ID"), **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
            required: ["collection_id"],
          ) do |collection_id:, account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.collection(collection_id, limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_set_aside",
            description: "List Set Aside threads with their group IDs.",
            properties: { **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
          ) do |account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.set_aside(limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_set_aside_groups",
            description: "List Set Aside groups and thread counts.",
            properties: ACCOUNT_PROPERTIES,
          ) { |account: nil| run(@client.set_aside_groups(account: account)) }

          define_tool(
            name: "hey_set_aside_group",
            description: "List threads in a Set Aside group.",
            properties: { group_id: string_prop("Set Aside group ID"), **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
            required: ["group_id"],
          ) do |group_id:, account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.set_aside_group(group_id, limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_workflows",
            description: "List HEY workflows and their account IDs.",
            properties: { **ACCOUNT_PROPERTIES, **LIMIT_PROPERTIES },
          ) { |account: nil, limit: nil, fetch_all: false| run(@client.workflows(limit: limit, fetch_all: fetch_all, account: account)) }

          define_tool(
            name: "hey_workflow",
            description: "List a workflow's stages. hey-cli does not accept --limit/--all on workflow view.",
            properties: { workflow_id: string_prop("Workflow ID"), **ACCOUNT_PROPERTIES },
            required: ["workflow_id"],
          ) { |workflow_id:, account: nil| run(@client.workflow(workflow_id, account: account)) }

          define_tool(
            name: "hey_clips",
            description: "List the newest page of saved HEY clips.",
            properties: ACCOUNT_PROPERTIES,
          ) { |account: nil| run(@client.clips(account: account)) }

          define_tool(
            name: "hey_snippets",
            description: "List reusable HEY email snippets.",
            properties: ACCOUNT_PROPERTIES,
          ) { |account: nil| run(@client.snippets(account: account)) }

          define_tool(
            name: "hey_search",
            description: "Search HEY threads via the official CLI. Call hey_search_filters for allowed --in/--date/--attachment values.",
            properties: {
              query: string_prop("Free-text search"),
              required: string_prop("Terms that must all match"),
              any: string_prop("Terms of which any may match"),
              none: string_prop("Terms to exclude"),
              exact: string_prop("Exact phrase"),
              from: string_prop("Sender email or name"),
              to: string_prop("Recipient email or name"),
              subject: string_prop("Subject text"),
              date: string_prop("last_7_days, last_30_days, last_90_days, or a four-digit year"),
              inbox: string_prop("Box filter from hey_search_filters (imbox, feed, papertrail, trash)"),
              label: string_prop("Label name or ID"),
              attachment: string_prop("any, images, pdfs, calendar_invites, documents, spreadsheets, presentations, media, zip_files"),
              **ACCOUNT_PROPERTIES,
              **CURSOR_PROPERTIES,
            },
          ) do |query: nil, required: nil, any: nil, none: nil, exact: nil, from: nil, to: nil,
                 subject: nil, date: nil, inbox: nil, label: nil, attachment: nil,
                 account: nil, fetch_all: false, page: nil|
            if [query, required, any, none, exact, from, to, subject, date, inbox, label, attachment].all?(&:blank?)
              next text_response("ERROR: provide query or at least one search refinement")
            end

            run(
              @client.search(
                query,
                required: required, any: any, none: none, exact: exact, from: from, to: to,
                subject: subject, date: date, inbox: inbox, label: label, attachment: attachment,
                fetch_all: fetch_all, page: page, account: account,
              ),
            )
          end

          define_tool(
            name: "hey_search_filters",
            description: "List allowed HEY search refinement values for --in, --date, --label, and --attachment.",
            properties: ACCOUNT_PROPERTIES,
          ) { |account: nil| run(@client.search_filters(account: account)) }

          define_tool(
            name: "hey_screener",
            description: "List first-time senders waiting in The Screener (clearance IDs, not contact IDs).",
            properties: {
              count: boolean_prop("Return only the number waiting"),
              **ACCOUNT_PROPERTIES,
              **CURSOR_PROPERTIES,
            },
          ) do |count: false, account: nil, fetch_all: false, page: nil|
            run(@client.screener(fetch_all: fetch_all, page: page, count: count, account: account))
          end

          define_tool(
            name: "hey_screener_history",
            description: "List senders already screened. Uses --page/--all; hey-cli does not accept --limit.",
            properties: { **ACCOUNT_PROPERTIES, **CURSOR_PROPERTIES },
          ) do |account: nil, fetch_all: false, page: nil|
            run(@client.screener_history(fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_threads",
            description: "Read a HEY email thread via `hey thread read`. Bodies are Markdown unless html is true. Entries include recipients and inbound received_via when hydrated.",
            properties: {
              topic_id: topic_id_prop,
              html: boolean_prop("Return original HTML instead of Markdown"),
              markdown: boolean_prop("Write the thread as one Markdown document"),
              allow_partial: boolean_prop("Return a partial thread instead of failing when a limit is hit"),
            },
            required: ["topic_id"],
          ) do |topic_id:, html: false, markdown: false, allow_partial: false|
            run(@client.threads(topic_id, html: html, markdown: markdown, allow_partial: allow_partial))
          end

          define_tool(
            name: "hey_attachments",
            description: "List files attached to a HEY thread. IDs look like 456:1.",
            properties: { topic_id: topic_id_prop },
            required: ["topic_id"],
          ) { |topic_id:| run(@client.attachments(topic_id)) }

          define_tool(
            name: "hey_drafts",
            description: "List HEY drafts via `hey draft list`.",
            properties: { **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
          ) do |account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.drafts(limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_draft",
            description: "Read a HEY draft. Body is Markdown.",
            properties: { draft_id: string_prop("Draft ID"), **ACCOUNT_PROPERTIES },
            required: ["draft_id"],
          ) { |draft_id:, account: nil| run(@client.draft_show(draft_id, account: account)) }

          define_tool(
            name: "hey_bubble_list",
            description: "List bubbled-up and scheduled Bubble Up threads.",
          ) { run(@client.bubble_list) }
        end

        def define_contact_tools
          define_tool(
            name: "hey_contacts",
            description: "List HEY contacts.",
            properties: { **ACCOUNT_PROPERTIES, **CURSOR_PROPERTIES },
          ) do |account: nil, fetch_all: false, page: nil|
            run(@client.contacts(fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_contact",
            description: "Show a HEY contact, aliases, screening status, and private note.",
            properties: { contact_id: string_prop("Contact ID"), html: boolean_prop("Return the note as HTML"), **ACCOUNT_PROPERTIES },
            required: ["contact_id"],
          ) { |contact_id:, html: false, account: nil| run(@client.contact(contact_id, html: html, account: account)) }

          define_tool(
            name: "hey_contact_threads",
            description: "List every thread with a contact, seen and unseen.",
            properties: { contact_id: string_prop("Contact ID"), **ACCOUNT_PROPERTIES, **PAGE_PROPERTIES },
            required: ["contact_id"],
          ) do |contact_id:, account: nil, limit: nil, fetch_all: false, page: nil|
            run(@client.contact_threads(contact_id, limit: limit, fetch_all: fetch_all, page: page, account: account))
          end

          define_tool(
            name: "hey_contact_note",
            description: "Read a contact's private note.",
            properties: { contact_id: string_prop("Contact ID"), html: boolean_prop("Return HTML"), **ACCOUNT_PROPERTIES },
            required: ["contact_id"],
          ) { |contact_id:, html: false, account: nil| run(@client.contact_note_show(contact_id, html: html, account: account)) }
        end

        def define_calendar_read_tools
          define_tool(name: "hey_calendars", description: "List HEY calendars via `hey calendar list`.") do
            run(@client.calendars)
          end

          define_tool(
            name: "hey_events",
            description: "List calendar events via `hey event list`. For today's schedule use hey_event_day.",
            properties: {
              calendar_id: string_prop("Calendar ID; omit to read every calendar"),
              starts_on: string_prop("Start date YYYY-MM-DD"),
              ends_on: string_prop("End date YYYY-MM-DD"),
              **LIMIT_PROPERTIES,
            },
          ) do |calendar_id: nil, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false|
            run(@client.events(calendar_id: calendar_id, starts_on: starts_on, ends_on: ends_on, limit: limit, fetch_all: fetch_all))
          end

          define_tool(
            name: "hey_recordings",
            description: "Deprecated alias for hey_events. List HEY calendar events.",
            properties: {
              calendar_id: string_prop("Calendar ID"),
              starts_on: string_prop("Start date YYYY-MM-DD"),
              ends_on: string_prop("End date YYYY-MM-DD"),
              **LIMIT_PROPERTIES,
            },
            required: ["calendar_id"],
          ) do |calendar_id:, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false|
            run(@client.events(calendar_id: calendar_id, starts_on: starts_on, ends_on: ends_on, limit: limit, fetch_all: fetch_all))
          end

          define_tool(
            name: "hey_event_day",
            description: "Today's (or one day's) schedule as HEY draws it, recurrences expanded.",
            properties: { date: string_prop("Date YYYY-MM-DD; defaults to today"), **LIMIT_PROPERTIES },
          ) { |date: nil, limit: nil, fetch_all: false| run(@client.event_day(date, limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_event_week",
            description: "The week a date falls in, recurrences expanded.",
            properties: { date: string_prop("Date YYYY-MM-DD; defaults to today"), **LIMIT_PROPERTIES },
          ) { |date: nil, limit: nil, fetch_all: false| run(@client.event_week(date, limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_todo_list",
            description: "List HEY todos.",
            properties: {
              starts_on: string_prop("Start date YYYY-MM-DD"),
              ends_on: string_prop("End date YYYY-MM-DD"),
              **LIMIT_PROPERTIES,
            },
          ) do |starts_on: nil, ends_on: nil, limit: nil, fetch_all: false|
            run(@client.todos(limit: limit, fetch_all: fetch_all, starts_on: starts_on, ends_on: ends_on))
          end

          define_tool(
            name: "hey_habits",
            description: "List HEY habits for the week a date falls in.",
            properties: { date: string_prop("Date YYYY-MM-DD whose week to read") },
          ) { |date: nil| run(@client.habits(date: date)) }

          define_tool(
            name: "hey_timetrack_current",
            description: "Show the current HEY time tracking entry.",
          ) { run(@client.timetrack("current")) }

          define_tool(
            name: "hey_timetrack_list",
            description: "List completed HEY time tracking entries, newest first.",
            properties: { category: string_prop("Category ID"), **LIMIT_PROPERTIES },
          ) do |category: nil, limit: nil, fetch_all: false|
            run(@client.timetrack_list(limit: limit, fetch_all: fetch_all, category: category))
          end

          define_tool(
            name: "hey_timetrack_categories",
            description: "List HEY time tracking categories.",
          ) { run(@client.timetrack_categories) }

          define_tool(
            name: "hey_journal_list",
            description: "List HEY journal entries.",
            properties: {
              starts_on: string_prop("Start date YYYY-MM-DD"),
              ends_on: string_prop("End date YYYY-MM-DD"),
              **LIMIT_PROPERTIES,
            },
          ) do |starts_on: nil, ends_on: nil, limit: nil, fetch_all: false|
            run(@client.journal_list(limit: limit, fetch_all: fetch_all, starts_on: starts_on, ends_on: ends_on))
          end

          define_tool(
            name: "hey_journal_read",
            description: "Read a HEY journal entry.",
            properties: {
              date: string_prop("Date YYYY-MM-DD; defaults to today"),
              html: boolean_prop("Include HTML"),
            },
          ) { |date: nil, html: false| run(@client.journal_read(date: date, html: html)) }
        end

        def define_write_mail_tools
          define_tool(
            name: "hey_compose",
            description: "Compose and send an email, or save a draft. Prefer paragraphs (Markdown).",
            properties: {
              subject: string_prop("Email subject"),
              to: string_prop("Comma-separated recipients"),
              cc: string_prop("Comma-separated CC recipients"),
              bcc: string_prop("Comma-separated BCC recipients"),
              thread_id: string_prop("Optional existing thread ID"),
              from: string_prop("Sender email or ID from hey_account_senders"),
              draft: boolean_prop("Save a draft instead of sending"),
              no_name_tag: boolean_prop("Leave the sender's HEY name tag off"),
              **ACCOUNT_PROPERTIES,
              **body_properties,
            },
            write: true,
          ) do |subject: nil, to: nil, cc: nil, bcc: nil, thread_id: nil, from: nil, draft: false,
                 no_name_tag: false, account: nil, paragraphs: nil, message: nil, message_html: nil, as_html: false|
            payload = hey_write_payload(message: message, paragraphs: paragraphs, message_html: message_html, as_html: as_html)
            if payload.empty? && !draft
              raise "message, paragraphs, or message_html is required unless draft is true"
            end

            run(
              @client.compose(
                subject: subject,
                to: to,
                cc: cc,
                bcc: bcc,
                thread_id: thread_id,
                from: from,
                draft: draft,
                no_name_tag: no_name_tag,
                account: account,
                **payload,
              ),
            )
          end

          define_tool(
            name: "hey_reply",
            description: "Reply to a HEY thread. Prefer paragraphs (Markdown).",
            properties: {
              topic_id: topic_id_prop,
              draft: boolean_prop("Save a reply draft instead of sending"),
              **body_properties,
            },
            required: ["topic_id"],
            write: true,
          ) do |topic_id:, draft: false, paragraphs: nil, message: nil, message_html: nil, as_html: false|
            payload = hey_write_payload(message: message, paragraphs: paragraphs, message_html: message_html, as_html: as_html)
            raise "message, paragraphs, or message_html is required unless draft is true" if payload.empty? && !draft

            run(@client.reply(topic_id, draft: draft, **payload))
          end

          define_tool(
            name: "hey_forward",
            description: "Forward the latest message in a HEY thread.",
            properties: {
              topic_id: topic_id_prop,
              to: string_prop("Recipient email"),
              **body_properties,
            },
            required: ["topic_id", "to"],
            write: true,
          ) do |topic_id:, to:, paragraphs: nil, message: nil, message_html: nil, as_html: false|
            payload = hey_write_payload(message: message, paragraphs: paragraphs, message_html: message_html, as_html: as_html)
            run(@client.forward(topic_id, to: to, **payload))
          end

          define_tool(
            name: "hey_bulk_reply_preview",
            description: "Read-only preview of a bulk reply: threads and exact To/CC/BCC recipients.",
            properties: { posting_ids: posting_ids_prop },
            required: ["posting_ids"],
          ) { |posting_ids:| run(@client.bulk_reply_preview(posting_ids)) }

          define_tool(
            name: "hey_bulk_reply_send",
            description: "Send one reply to many threads. Always preview first.",
            properties: { posting_ids: posting_ids_prop, **body_properties },
            required: ["posting_ids"],
            write: true,
          ) do |posting_ids:, paragraphs: nil, message: nil, message_html: nil, as_html: false|
            payload = hey_write_payload(message: message, paragraphs: paragraphs, message_html: message_html, as_html: as_html)
            raise "message, paragraphs, or message_html is required" if payload.empty?

            run(@client.bulk_reply_send(posting_ids, **payload))
          end

          define_tool(
            name: "hey_bulk_reply_undo",
            description: "Recall a delayed bulk reply while HEY's undo window is open.",
            properties: { delivery_id: string_prop("Bulk reply delivery ID") },
            required: ["delivery_id"],
            write: true,
          ) { |delivery_id:| run(@client.bulk_reply_undo(delivery_id)) }

          define_tool(
            name: "hey_share",
            description: "Get a sharing link for a HEY thread.",
            properties: { topic_id: topic_id_prop },
            required: ["topic_id"],
            write: true,
          ) { |topic_id:| run(@client.share(topic_id)) }

          define_tool(
            name: "hey_unshare",
            description: "Turn off a HEY thread sharing link.",
            properties: { topic_id: topic_id_prop },
            required: ["topic_id"],
            write: true,
          ) { |topic_id:| run(@client.unshare(topic_id)) }

          %w[seen unseen].each do |action|
            define_tool(
              name: "hey_#{action}",
              description: "Mark HEY postings as #{action}. Takes box item IDs, not topic_id.",
              properties: { posting_ids: posting_ids_prop },
              required: ["posting_ids"],
              write: true,
            ) { |posting_ids:| run(@client.public_send(action, posting_ids)) }
          end

          define_tool(
            name: "hey_move",
            description: "Move threads to Imbox, The Feed, Set Aside, Reply Later, or Paper Trail. Bundle rows cannot be moved; unbundle first.",
            properties: {
              posting_ids: posting_ids_prop,
              to: string_prop("Destination box name, kind, or ID"),
            },
            required: ["posting_ids", "to"],
            write: true,
          ) { |posting_ids:, to:| run(@client.move(posting_ids, to: to)) }

          define_tool(
            name: "hey_bubble_up",
            description: "Bubble threads up now or on a schedule. Pass exactly one of now/on/tomorrow/weekend/next_week.",
            properties: {
              posting_ids: posting_ids_prop,
              now: boolean_prop("Bubble up immediately"),
              on: string_prop("Bubble up on YYYY-MM-DD"),
              tomorrow: boolean_prop("Bubble up tomorrow morning"),
              weekend: boolean_prop("Bubble up Saturday morning"),
              next_week: boolean_prop("Bubble up next Monday morning"),
            },
            required: ["posting_ids"],
            write: true,
          ) do |posting_ids:, now: false, on: nil, tomorrow: false, weekend: false, next_week: false|
            run(@client.bubble_up(posting_ids, now: now, on: on, tomorrow: tomorrow, weekend: weekend, next_week: next_week))
          end

          define_tool(
            name: "hey_bubble_pop",
            description: "Cancel a scheduled bubble-up.",
            properties: { posting_ids: posting_ids_prop },
            required: ["posting_ids"],
            write: true,
          ) { |posting_ids:| run(@client.bubble_pop(posting_ids)) }

          {
            "trash" => "Move threads to Trash",
            "spam" => "Mark threads as spam",
            "ignore" => "Ignore future activity on threads",
            "stop_ignoring" => "Resume attention for ignored threads",
          }.each do |action, description|
            define_tool(
              name: "hey_#{action}",
              description: "#{description}. Takes box item IDs.",
              properties: { posting_ids: posting_ids_prop },
              required: ["posting_ids"],
              write: true,
            ) { |posting_ids:| run(@client.public_send(action, posting_ids)) }
          end

          define_tool(
            name: "hey_draft_edit",
            description: "Revise a draft. Each flag replaces its field; omitted fields are kept.",
            properties: {
              draft_id: string_prop("Draft ID"),
              to: string_prop("Replace To recipients"),
              cc: string_prop("Replace CC recipients"),
              bcc: string_prop("Replace BCC recipients"),
              subject: string_prop("Replace subject"),
              from: string_prop("Change sender email or ID; stays in the draft's account"),
              **ACCOUNT_PROPERTIES,
              **body_properties,
            },
            required: ["draft_id"],
            write: true,
          ) do |draft_id:, to: nil, cc: nil, bcc: nil, subject: nil, from: nil, account: nil,
                 paragraphs: nil, message: nil, message_html: nil, as_html: false|
            payload = hey_write_payload(message: message, paragraphs: paragraphs, message_html: message_html, as_html: as_html)
            run(@client.draft_edit(draft_id, to: to, cc: cc, bcc: bcc, subject: subject, from: from, account: account, **payload))
          end

          define_tool(
            name: "hey_draft_send",
            description: "Send a HEY draft.",
            properties: { draft_id: string_prop("Draft ID"), **ACCOUNT_PROPERTIES },
            required: ["draft_id"],
            write: true,
          ) { |draft_id:, account: nil| run(@client.draft_send(draft_id, account: account)) }

          define_tool(
            name: "hey_draft_delete",
            description: "Trash HEY drafts.",
            properties: { draft_ids: array_prop("Draft IDs"), **ACCOUNT_PROPERTIES },
            required: ["draft_ids"],
            write: true,
          ) { |draft_ids:, account: nil| run(@client.draft_delete(draft_ids, account: account)) }

          define_tool(
            name: "hey_screener_approve",
            description: "Let a first-time sender through. --box and --seen apply to one ID only.",
            properties: {
              clearance_ids: array_prop("Screener clearance IDs"),
              box: string_prop("Deliver into this box instead of Imbox"),
              seen: boolean_prop("Deliver already marked seen"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["clearance_ids"],
            write: true,
          ) { |clearance_ids:, box: nil, seen: false, account: nil| run(@client.screener_approve(clearance_ids, box: box, seen: seen, account: account)) }

          define_tool(
            name: "hey_screener_deny",
            description: "Turn first-time senders away. --spam also trains HEY's filter.",
            properties: {
              clearance_ids: array_prop("Screener clearance IDs"),
              spam: boolean_prop("Also mark what they sent as spam"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["clearance_ids"],
            write: true,
          ) { |clearance_ids:, spam: false, account: nil| run(@client.screener_deny(clearance_ids, spam: spam, account: account)) }

          define_tool(
            name: "hey_screener_clear",
            description: "Empty The Screener without deciding. Senders reappear on their next email.",
            properties: ACCOUNT_PROPERTIES,
            write: true,
          ) { |account: nil| run(@client.screener_clear(account: account)) }
        end

        def define_write_org_tools
          define_tool(
            name: "hey_label_add",
            description: "Add an existing label to threads. Takes box item IDs.",
            properties: { posting_ids: posting_ids_prop, label_id: string_prop("Label ID"), **ACCOUNT_PROPERTIES },
            required: ["posting_ids", "label_id"],
            write: true,
          ) { |posting_ids:, label_id:, account: nil| run(@client.label_add(posting_ids, to: label_id, account: account)) }

          define_tool(
            name: "hey_label_create",
            description: "Create a label and add it to at least one thread.",
            properties: {
              name: string_prop("Label name"),
              posting_ids: posting_ids_prop,
              **ACCOUNT_PROPERTIES,
            },
            required: ["name", "posting_ids"],
            write: true,
          ) { |name:, posting_ids:, account: nil| run(@client.label_create(name, posting_ids, account: account)) }

          define_tool(
            name: "hey_label_remove",
            description: "Remove a label, or every label with from=all.",
            properties: {
              posting_ids: posting_ids_prop,
              from: string_prop("Label ID, or all"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["posting_ids", "from"],
            write: true,
          ) { |posting_ids:, from:, account: nil| run(@client.label_remove(posting_ids, from: from, account: account)) }

          define_tool(
            name: "hey_collection_create",
            description: "Create a HEY collection.",
            properties: {
              name: string_prop("Collection name"),
              summary: string_prop("Optional summary"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["name"],
            write: true,
          ) { |name:, summary: nil, account: nil| run(@client.collection_create(name, summary: summary, account: account)) }

          define_tool(
            name: "hey_collection_update",
            description: "Rename a collection or change its summary.",
            properties: {
              collection_id: string_prop("Collection ID"),
              name: string_prop("New name"),
              summary: string_prop("New summary"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["collection_id"],
            write: true,
          ) { |collection_id:, name: nil, summary: nil, account: nil| run(@client.collection_update(collection_id, name: name, summary: summary, account: account)) }

          define_tool(
            name: "hey_collection_add",
            description: "Add a thread to a collection. Takes topic_id.",
            properties: { topic_id: topic_id_prop, collection_id: string_prop("Collection ID"), **ACCOUNT_PROPERTIES },
            required: ["topic_id", "collection_id"],
            write: true,
          ) { |topic_id:, collection_id:, account: nil| run(@client.collection_add(topic_id, to: collection_id, account: account)) }

          define_tool(
            name: "hey_collection_remove",
            description: "Remove a thread from a collection. Takes topic_id.",
            properties: { topic_id: topic_id_prop, collection_id: string_prop("Collection ID"), **ACCOUNT_PROPERTIES },
            required: ["topic_id", "collection_id"],
            write: true,
          ) { |topic_id:, collection_id:, account: nil| run(@client.collection_remove(topic_id, from: collection_id, account: account)) }

          define_tool(
            name: "hey_set_aside_group_create",
            description: "Gather threads into a new Set Aside group. Takes box item IDs.",
            properties: { posting_ids: posting_ids_prop, **ACCOUNT_PROPERTIES },
            required: ["posting_ids"],
            write: true,
          ) { |posting_ids:, account: nil| run(@client.set_aside_group_create(posting_ids, account: account)) }

          define_tool(
            name: "hey_set_aside_group_add",
            description: "File threads into a Set Aside group.",
            properties: { posting_ids: posting_ids_prop, group_id: string_prop("Group ID"), **ACCOUNT_PROPERTIES },
            required: ["posting_ids", "group_id"],
            write: true,
          ) { |posting_ids:, group_id:, account: nil| run(@client.set_aside_group_add(posting_ids, to: group_id, account: account)) }

          define_tool(
            name: "hey_set_aside_group_remove",
            description: "Take threads out of their Set Aside group; they stay in Set Aside.",
            properties: { posting_ids: posting_ids_prop, **ACCOUNT_PROPERTIES },
            required: ["posting_ids"],
            write: true,
          ) { |posting_ids:, account: nil| run(@client.set_aside_group_remove(posting_ids, account: account)) }

          define_tool(
            name: "hey_set_aside_group_delete",
            description: "Dissolve a Set Aside group; threads go to Previously Seen.",
            properties: { group_id: string_prop("Group ID"), **ACCOUNT_PROPERTIES },
            required: ["group_id"],
            write: true,
          ) { |group_id:, account: nil| run(@client.set_aside_group_delete(group_id, account: account)) }

          define_tool(
            name: "hey_workflow_create",
            description: "Create a workflow. Needs --account when more than one mail account is linked.",
            properties: { name: string_prop("Workflow name"), **ACCOUNT_PROPERTIES },
            required: ["name"],
            write: true,
          ) { |name:, account: nil| run(@client.workflow_create(name, account: account)) }

          define_tool(
            name: "hey_workflow_update",
            description: "Rename a workflow.",
            properties: { workflow_id: string_prop("Workflow ID"), name: string_prop("New name"), **ACCOUNT_PROPERTIES },
            required: ["workflow_id", "name"],
            write: true,
          ) { |workflow_id:, name:, account: nil| run(@client.workflow_update(workflow_id, name: name, account: account)) }

          define_tool(
            name: "hey_workflow_stage_create",
            description: "Add an Untitled stage to a workflow, then rename it.",
            properties: { workflow_id: string_prop("Workflow ID"), **ACCOUNT_PROPERTIES },
            required: ["workflow_id"],
            write: true,
          ) { |workflow_id:, account: nil| run(@client.workflow_stage_create(workflow_id, account: account)) }

          define_tool(
            name: "hey_workflow_stage_update",
            description: "Rename a workflow stage.",
            properties: {
              workflow_id: string_prop("Workflow ID"),
              stage_id: string_prop("Stage ID"),
              name: string_prop("New stage name"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["workflow_id", "stage_id", "name"],
            write: true,
          ) { |workflow_id:, stage_id:, name:, account: nil| run(@client.workflow_stage_update(workflow_id, stage_id, name: name, account: account)) }

          define_tool(
            name: "hey_workflow_add",
            description: "Add a thread to a workflow stage. Takes topic_id.",
            properties: {
              topic_id: topic_id_prop,
              workflow_id: string_prop("Workflow ID"),
              stage_id: string_prop("Stage ID"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["topic_id", "workflow_id"],
            write: true,
          ) { |topic_id:, workflow_id:, stage_id: nil, account: nil| run(@client.workflow_add(topic_id, to: workflow_id, stage: stage_id, account: account)) }

          define_tool(
            name: "hey_workflow_move",
            description: "Move a thread to another workflow stage. Takes topic_id.",
            properties: {
              topic_id: topic_id_prop,
              workflow_id: string_prop("Workflow ID"),
              stage_id: string_prop("Destination stage ID"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["topic_id", "workflow_id", "stage_id"],
            write: true,
          ) { |topic_id:, workflow_id:, stage_id:, account: nil| run(@client.workflow_move(topic_id, workflow: workflow_id, to: stage_id, account: account)) }

          define_tool(
            name: "hey_workflow_remove",
            description: "Remove a thread from a workflow. Takes topic_id.",
            properties: { topic_id: topic_id_prop, workflow_id: string_prop("Workflow ID"), **ACCOUNT_PROPERTIES },
            required: ["topic_id", "workflow_id"],
            write: true,
          ) { |topic_id:, workflow_id:, account: nil| run(@client.workflow_remove(topic_id, from: workflow_id, account: account)) }

          define_tool(
            name: "hey_clip_create",
            description: "Save a passage from a thread entry. Content must appear in the source entry.",
            properties: {
              entry_id: string_prop("Source entry ID from hey_threads"),
              content: string_prop("Exact passage to save"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["entry_id", "content"],
            write: true,
          ) { |entry_id:, content:, account: nil| run(@client.clip_create(entry_id, content: content, account: account)) }

          define_tool(
            name: "hey_clip_delete",
            description: "Delete a saved clip.",
            properties: { clip_id: string_prop("Clip ID"), **ACCOUNT_PROPERTIES },
            required: ["clip_id"],
            write: true,
          ) { |clip_id:, account: nil| run(@client.clip_delete(clip_id, account: account)) }

          define_tool(
            name: "hey_snippet_create",
            description: "Create a reusable email snippet.",
            properties: {
              name: string_prop("Snippet name"),
              content: string_prop("Plain-text / Markdown snippet"),
              content_html: string_prop("Raw HTML snippet"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["name"],
            write: true,
          ) { |name:, content: nil, content_html: nil, account: nil| run(@client.snippet_create(name: name, content: content, content_html: content_html, account: account)) }

          define_tool(
            name: "hey_snippet_update",
            description: "Update a snippet. Omitted fields stay as they are.",
            properties: {
              snippet_id: string_prop("Snippet ID"),
              name: string_prop("New name"),
              content: string_prop("New plain-text content"),
              content_html: string_prop("New HTML content"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["snippet_id"],
            write: true,
          ) { |snippet_id:, name: nil, content: nil, content_html: nil, account: nil| run(@client.snippet_update(snippet_id, name: name, content: content, content_html: content_html, account: account)) }

          define_tool(
            name: "hey_snippet_delete",
            description: "Delete a snippet.",
            properties: { snippet_id: string_prop("Snippet ID"), **ACCOUNT_PROPERTIES },
            required: ["snippet_id"],
            write: true,
          ) { |snippet_id:, account: nil| run(@client.snippet_delete(snippet_id, account: account)) }

          define_tool(
            name: "hey_contact_add",
            description: "Add a HEY contact.",
            properties: {
              name: string_prop("Contact name"),
              email: string_prop("Email address"),
              alias_addresses: string_prop("Comma-separated aliases"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["name", "email"],
            write: true,
          ) { |name:, email:, alias_addresses: nil, account: nil| run(@client.contact_add(name: name, email: email, alias_addresses: alias_addresses, account: account)) }

          define_tool(
            name: "hey_contact_update",
            description: "Update a contact. Omitted fields are preserved. alias_addresses replaces the whole list.",
            properties: {
              contact_id: string_prop("Contact ID"),
              name: string_prop("New name"),
              email: string_prop("New email"),
              alias_addresses: string_prop("Replacement alias list; empty string clears it"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["contact_id"],
            write: true,
          ) { |contact_id:, name: nil, email: nil, alias_addresses: nil, account: nil| run(@client.contact_update(contact_id, name: name, email: email, alias_addresses: alias_addresses, account: account)) }

          {
            "hide" => "Hide a contact without permanently deleting it",
            "show_again" => "Show a hidden contact again",
            "bundle" => "Group this contact's mail into one row",
            "unbundle" => "List this contact's mail as separate threads",
          }.each do |action, description|
            define_tool(
              name: "hey_contact_#{action}",
              description: "#{description}.",
              properties: { contact_id: string_prop("Contact ID"), **ACCOUNT_PROPERTIES },
              required: ["contact_id"],
              write: true,
            ) { |contact_id:, account: nil| run(@client.public_send("contact_#{action}", contact_id, account: account)) }
          end

          define_tool(
            name: "hey_contact_note_set",
            description: "Set a contact's private note.",
            properties: {
              contact_id: string_prop("Contact ID"),
              note: string_prop("Note as Markdown / plain text"),
              note_html: string_prop("Raw HTML note"),
              **ACCOUNT_PROPERTIES,
            },
            required: ["contact_id"],
            write: true,
          ) { |contact_id:, note: nil, note_html: nil, account: nil| run(@client.contact_note_set(contact_id, note: note, note_html: note_html, account: account)) }

          define_tool(
            name: "hey_contact_note_delete",
            description: "Delete a contact's private note.",
            properties: { contact_id: string_prop("Contact ID"), **ACCOUNT_PROPERTIES },
            required: ["contact_id"],
            write: true,
          ) { |contact_id:, account: nil| run(@client.contact_note_delete(contact_id, account: account)) }
        end

        def define_write_calendar_tools
          define_tool(
            name: "hey_todo_add",
            description: "Create a HEY todo.",
            properties: { title: string_prop("Todo title"), date: string_prop("Date YYYY-MM-DD") },
            required: ["title"],
            write: true,
          ) { |title:, date: nil| run(@client.todo_add(title, date: date)) }

          {
            "complete" => :todo_complete,
            "uncomplete" => :todo_uncomplete,
            "delete" => :todo_delete,
          }.each do |action, method|
            define_tool(
              name: "hey_todo_#{action}",
              description: "#{action.capitalize} a HEY todo.",
              properties: { todo_id: string_prop("Todo ID") },
              required: ["todo_id"],
              write: true,
            ) { |todo_id:| run(@client.public_send(method, todo_id)) }
          end

          define_tool(
            name: "hey_event_add",
            description: "Create a calendar event. No start_time means all-day; start_time without end_time lasts an hour.",
            properties: {
              title: string_prop("Event title"),
              starts_on: string_prop("Date YYYY-MM-DD"),
              start_time: string_prop("Start time HH:MM"),
              end_time: string_prop("End time HH:MM"),
              calendar_id: string_prop("Calendar ID"),
              repeat: string_prop("Repeat rule, e.g. every_weekday"),
              remind: string_prop("Reminder, e.g. 10m"),
              time_zone: string_prop("IANA time zone"),
            },
            required: ["title"],
            write: true,
          ) do |title:, starts_on: nil, start_time: nil, end_time: nil, calendar_id: nil, repeat: nil, remind: nil, time_zone: nil|
            run(@client.event_add(title, starts_on: starts_on, start_time: start_time, end_time: end_time, calendar_id: calendar_id, repeat: repeat, remind: remind, time_zone: time_zone))
          end

          define_tool(
            name: "hey_event_edit",
            description: "Edit a calendar event. An id alone edits the whole series; one day needs occurrence plus apply_to (current or future).",
            properties: {
              event_id: string_prop("Event / series ID"),
              date: string_prop("Occurrence date YYYY-MM-DD to find the event"),
              title: string_prop("New title"),
              starts_on: string_prop("New date YYYY-MM-DD"),
              start_time: string_prop("New start time HH:MM"),
              end_time: string_prop("New end time HH:MM"),
              calendar_id: string_prop("Calendar to search, or with occurrence the calendar the day moves to"),
              countdown: string_prop("Keep or set a countdown; otherwise an edit removes one"),
              occurrence: string_prop("occurrence_id from event day/week, e.g. 4821_2026-09-15"),
              apply_to: string_prop("With occurrence: current (that day) or future (that day and after)"),
              repeat: string_prop("Required with apply_to=future; e.g. every_week or custom"),
              repeat_times: string_prop("Finite series remaining count from the edited day"),
              repeat_until: string_prop("Finite series last day YYYY-MM-DD"),
              allow_plain_notes: boolean_prop("Accept flattening notes to plain text"),
            },
            required: ["event_id"],
            write: true,
          ) do |event_id:, date: nil, title: nil, starts_on: nil, start_time: nil, end_time: nil,
                 calendar_id: nil, countdown: nil, occurrence: nil, apply_to: nil, repeat: nil,
                 repeat_times: nil, repeat_until: nil, allow_plain_notes: false|
            run(
              @client.event_edit(
                event_id,
                date: date,
                title: title,
                starts_on: starts_on,
                start_time: start_time,
                end_time: end_time,
                calendar_id: calendar_id,
                countdown: countdown,
                occurrence: occurrence,
                apply_to: apply_to,
                repeat: repeat,
                repeat_times: repeat_times,
                repeat_until: repeat_until,
                allow_plain_notes: allow_plain_notes,
              ),
            )
          end

          define_tool(
            name: "hey_event_delete",
            description: "Delete a calendar event.",
            properties: { event_id: string_prop("Event / series ID") },
            required: ["event_id"],
            write: true,
          ) { |event_id:| run(@client.event_delete(event_id)) }

          define_tool(
            name: "hey_habit_create",
            description: "Create a habit. Defaults to every day with weights and blue.",
            properties: {
              name: string_prop("Habit name"),
              icon: string_prop("Icon name, e.g. music"),
              color: string_prop("Color name, e.g. green"),
              days: string_prop("Weekdays: mon,wed,fri or 0-6 (Sunday=0)"),
            },
            required: ["name"],
            write: true,
          ) { |name:, icon: nil, color: nil, days: nil| run(@client.habit_create(name, icon: icon, color: color, days: days)) }

          define_tool(
            name: "hey_habit_edit",
            description: "Edit only the supplied habit fields.",
            properties: {
              habit_id: string_prop("Habit ID"),
              name: string_prop("New name"),
              icon: string_prop("New icon"),
              color: string_prop("New color"),
              days: string_prop("New weekdays"),
            },
            required: ["habit_id"],
            write: true,
          ) { |habit_id:, name: nil, icon: nil, color: nil, days: nil| run(@client.habit_edit(habit_id, name: name, icon: icon, color: color, days: days)) }

          define_tool(
            name: "hey_habit_delete",
            description: "Permanently delete a habit and its history.",
            properties: { habit_id: string_prop("Habit ID") },
            required: ["habit_id"],
            write: true,
          ) { |habit_id:| run(@client.habit_delete(habit_id)) }

          %w[complete uncomplete].each do |action|
            define_tool(
              name: "hey_habit_#{action}",
              description: "#{action.capitalize} a HEY habit occurrence.",
              properties: { habit_id: string_prop("Habit ID"), date: string_prop("Date YYYY-MM-DD") },
              required: ["habit_id"],
              write: true,
            ) { |habit_id:, date: nil| run(@client.public_send("habit_#{action}", habit_id, date: date)) }
          end

          define_tool(
            name: "hey_timetrack_start",
            description: "Start HEY time tracking.",
            write: true,
          ) { run(@client.timetrack("start")) }

          define_tool(
            name: "hey_timetrack_stop",
            description: "Stop HEY time tracking, optionally filing it in a category.",
            properties: { category: string_prop("Category title; HEY creates it if missing") },
            write: true,
          ) { |category: nil| run(@client.timetrack("stop", category: category)) }

          define_tool(
            name: "hey_timetrack_edit",
            description: "Edit a completed time track. Editing a running track completes it.",
            properties: {
              track_id: string_prop("Time track ID"),
              start: string_prop("Start YYYY-MM-DDTHH:MM or RFC 3339"),
              finish: string_prop("End YYYY-MM-DDTHH:MM or RFC 3339"),
              category: string_prop("Category title"),
              notes: string_prop("Notes"),
            },
            required: ["track_id"],
            write: true,
          ) { |track_id:, start: nil, finish: nil, category: nil, notes: nil| run(@client.timetrack_edit(track_id, start: start, finish: finish, category: category, notes: notes)) }

          define_tool(
            name: "hey_timetrack_delete",
            description: "Delete a time track.",
            properties: { track_id: string_prop("Time track ID") },
            required: ["track_id"],
            write: true,
          ) { |track_id:| run(@client.timetrack_delete(track_id)) }

          define_tool(
            name: "hey_timetrack_category_create",
            description: "Create a time tracking category.",
            properties: { title: string_prop("Category title") },
            required: ["title"],
            write: true,
          ) { |title:| run(@client.timetrack_category_create(title)) }

          define_tool(
            name: "hey_timetrack_category_rename",
            description: "Rename a time tracking category.",
            properties: { category_id: string_prop("Category ID"), title: string_prop("New title") },
            required: ["category_id", "title"],
            write: true,
          ) { |category_id:, title:| run(@client.timetrack_category_rename(category_id, title)) }

          define_tool(
            name: "hey_timetrack_category_delete",
            description: "Delete a time tracking category. Existing tracks become uncategorized.",
            properties: { category_id: string_prop("Category ID") },
            required: ["category_id"],
            write: true,
          ) { |category_id:| run(@client.timetrack_category_delete(category_id)) }

          define_tool(
            name: "hey_journal_write",
            description: "Create or update a HEY journal entry. Empty content removes the day's entry.",
            properties: {
              content: string_prop("Journal content as Markdown"),
              content_html: string_prop("Raw HTML content"),
              date: string_prop("Date YYYY-MM-DD"),
            },
            write: true,
          ) { |content: nil, content_html: nil, date: nil| run(@client.journal_write(content, date: date, content_html: content_html)) }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Hey::Server)
