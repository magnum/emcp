# frozen_string_literal: true

class StaticPagesController < ApplicationController
  PAGES = %w[privacy-policy terms-and-conditions cookie-policy].freeze

  def show
    @slug = params[:slug].to_s
    raise ActionController::RoutingError, "Not Found" unless PAGES.include?(@slug)

    @template = template_for(@slug, I18n.locale.to_s)
    @template_file = Rails.root.join("app/views/static_pages/#{@template}.html.erb").to_s
    render :show
  end

  def self.page?(slug)
    PAGES.include?(slug.to_s)
  end

  private

  def template_for(slug, locale)
    [locale, I18n.default_locale.to_s].uniq.each do |loc|
      name = "#{slug}.#{loc}"
      return name if Rails.root.join("app/views/static_pages/#{name}.html.erb").file?
    end

    raise ActionController::RoutingError, "Not Found"
  end
end
