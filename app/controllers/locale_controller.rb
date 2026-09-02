# frozen_string_literal: true

class LocaleController < ApplicationController
  def set_session_locale
    locale = params[:locale].to_s
    if I18n.available_locales.map(&:to_s).include?(locale)
      session[:locale] = locale
    end
    redirect_to localized_redirect_target(locale)
  end

  private

  def localized_redirect_target(locale)
    referer = request.referer
    return root_path if referer.blank?

    uri = URI.parse(referer)
    return root_path unless uri.host.nil? || uri.host == request.host

    path = uri.path
    segments = path.split("/").reject(&:empty?)
    available = I18n.available_locales.map(&:to_s)
    segments.shift if segments.first.in?(available)
    slug = segments.first

    if StaticPagesController.page?(slug)
      new_path = if locale == I18n.default_locale.to_s
        "/#{slug}"
      else
        "/#{locale}/#{slug}"
      end
      query = sanitized_query(uri.query)
      return query.empty? ? new_path : "#{new_path}?#{query}"
    end

    query = sanitized_query(uri.query)
    query.empty? ? path : "#{path}?#{query}"
  rescue URI::InvalidURIError
    root_path
  end

  def sanitized_query(query_string)
    Rack::Utils.parse_query(query_string.to_s).except("locale").to_query
  end
end
