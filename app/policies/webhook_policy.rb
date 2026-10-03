# frozen_string_literal: true

class WebhookPolicy < ApplicationPolicy
  def destroy?
    admin?
  end

  def event?
    admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.none
    end
  end
end
