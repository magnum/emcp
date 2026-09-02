# frozen_string_literal: true

module WithLocale
  extend ActiveSupport::Concern

  included do
    before_action :set_locale
  end

  private

  def set_locale
    requested = static_page_path_locale
    requested = nil unless available_locale?(requested)

    locale = requested ||
             session[:locale].presence ||
             I18n.default_locale
    I18n.locale = locale
    session[:locale] = I18n.locale.to_s
  end

  # Locale belongs in the path only for legal pages (/it/privacy-policy).
  def static_page_path_locale
    params[:slug].present? ? params[:locale].presence : nil
  end

  def available_locale?(locale)
    locale.present? && I18n.available_locales.map(&:to_s).include?(locale.to_s)
  end
end
