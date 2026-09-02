class User < ApplicationRecord
  include ApiKeyable
  include Plannable

  rolify
  has_secure_password validations: false

  validates :email, presence: true, uniqueness: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: false
  validates :firstname, :lastname, presence: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  validate :password_or_oauth
  validate :password_confirmation_match, if: -> { password.present? }

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  after_create :create_default_plan

  def self.find_for_omniauth(auth)
    find_by(provider: auth.provider, uid: auth.uid).presence ||
      find_by(email: auth.info.email)
  end

  def self.from_omniauth(auth)
    user = find_for_omniauth(auth) || new
    user.email = auth.info.email
    user.firstname = user.firstname.presence || auth.info.first_name.presence || auth.info.name&.split&.first || "User"
    user.lastname = user.lastname.presence || auth.info.last_name.presence || auth.info.name&.split&.last || "Name"
    user.avatar_url = auth.info.image.presence || user.avatar_url
    user.provider = auth.provider
    user.uid = auth.uid
    user.save!
    user
  end

  def google_connected?
    provider == "google_oauth2"
  end

  def full_name
    "#{firstname} #{lastname}".strip
  end

  def admin?
    has_role?(:admin)
  end

  def create_default_plan
    plan_type = PlanType.find_by(code: "basic")
    return unless plan_type

    Plan.create!(
      plan_type: plan_type,
      user: self,
      valid_from: Date.current,
      valid_to: Date.current + 365.days
    )
  end

  private

  def password_or_oauth
    return if password_digest.present? || (provider.present? && uid.present?)
    errors.add(:base, "Password can't be blank") if password.blank?
  end

  def password_confirmation_match
    return if password == password_confirmation
    errors.add(:password_confirmation, "doesn't match Password")
  end
end
