# frozen_string_literal: true

class McpServerPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    owner? || admin?
  end

  def create?
    user.present?
  end

  def update?
    owner? || admin?
  end

  def destroy?
    owner? || admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if user&.admin?

      user.present? ? scope.where(user: user) : scope.none
    end
  end

  private

  def owner?
    record.is_a?(McpServer) && record.user_id == user&.id
  end
end
