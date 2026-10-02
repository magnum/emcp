module ApplicationHelper
  def google_oauth_configured?
    ENV["GOOGLE_CLIENT_ID"].present? &&
      ENV["GOOGLE_CLIENT_SECRET"].present?
  end

  def state_bg_color(state)
    case state.to_s
    when "created", "draft"
      "bg-gray-700"
    when "warning"
      "bg-yellow-500"
    when "running", "processing"
      "bg-blue-700"
    when "completed", "processed", "consumed"
      "bg-green-700"
    when "error"
      "bg-red-700"
    when "canceled", "expired"
      "bg-gray-700"
    else
      "bg-gray-700"
    end
  end

  def state_text_color(state)
    "text-white"
  end

  def badge(state, value = nil)
    content_tag(:span, value || state.to_s.humanize, class: "whitespace-nowrap rounded-md #{state_bg_color(state)} px-2 py-1 text-md font-medium #{state_text_color(state)}")
  end

  def catalog_path_for(server)
    server.context? ? contexts_path : mcp_servers_path
  end

  def catalog_heading_class
    "font1 text-4xl font-bold tracking-tight"
  end

  def catalog_nav_class(active)
    if active
      "#{catalog_heading_class} underline decoration-2 underline-offset-8"
    else
      "#{catalog_heading_class} text-stone-400 hover:text-stone-900 dark:text-zinc-500 dark:hover:text-zinc-100"
    end
  end
end
