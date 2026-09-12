# frozen_string_literal: true

class McpServerTypePolicy < ApplicationPolicy
  def destroy?
    false
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.none
    end
  end
end
