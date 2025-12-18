module StandardId
  class AuditLog < ApplicationRecord
    self.table_name = "standard_id_audit_logs"

    belongs_to :actor, polymorphic: true, optional: true
    belongs_to :target, polymorphic: true, optional: true

    validates :event_type, presence: true
    validates :occurred_at, presence: true
  end
end
