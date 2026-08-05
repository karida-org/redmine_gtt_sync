# frozen_string_literal: true

# Typed test doubles for the unit layer: small plain classes whose methods
# mirror the arities of the real Redmine models the builders read. OpenStruct
# (soft-deprecated, slated to leave Ruby's default gems) answered every getter
# and silently returned nil for anything argful or misspelled - each
# permission method needed an ad-hoc mocha stub, and a fake could drift from
# the real signatures without any test noticing. Here a builder calling a
# method the double doesn't define, or with an arity it doesn't accept, fails
# loudly instead.
#
# Only what the builders actually read is modelled; permission methods keep
# the real models' optional-user arity but ignore the argument (the fakes are
# state, not RBAC engines - the functional matrix tests cover real behavior).
module RedmineGttSync
  module TestDoubles
    # A named dictionary record (status, tracker, priority, user, version,
    # category...): the builders only read #id and #name.
    NamedRef = Struct.new(:id, :name, keyword_init: true)

    # Issue.reflect_on_association(...) result: only #klass is read.
    Reflection = Struct.new(:klass, keyword_init: true)

    # A journal change detail as IssueDocument.change reads it
    # (JournalDetail#property/#prop_key/#old_value/#value + ids for diff_url).
    ChangeDetail = Struct.new(
      :property, :prop_key, :old_value, :value, :journal_id, :id,
      keyword_init: true
    )

    # A CustomValue: #custom_field, #custom_field_id, #value.
    CustomValue = Struct.new(:custom_field, :custom_field_id, :value,
                             keyword_init: true)

    class CustomFieldDouble
      attr_reader :id, :name, :field_format, :multiple, :possible_values,
                  :is_required, :trackers

      def initialize(id:, name:, field_format:, multiple: false,
                     possible_values: nil, is_required: false, trackers: [],
                     value_options: nil)
        @id = id
        @name = name
        @field_format = field_format
        @multiple = multiple
        @possible_values = possible_values
        @is_required = is_required
        @trackers = trackers
        @value_options = value_options
      end

      # Real: CustomField#possible_values_options(object = nil) - [label, value]
      # pairs for user/version formats, resolved against +object+.
      def possible_values_options(_object = nil)
        @value_options || []
      end
    end

    # Real: Project#trackers is a relation; the schema builder only reads
    # .sorted off it.
    class TrackerSet
      def initialize(trackers)
        @trackers = trackers
      end

      def sorted
        @trackers
      end
    end

    class ProjectDouble
      attr_reader :id, :identifier, :name, :geom
      attr_accessor :issue_categories

      def initialize(id: 3, identifier: 'field-survey', name: 'Field Survey',
                     geom: nil, issue_categories: [], trackers: [])
        @id = id
        @identifier = identifier
        @name = name
        @geom = geom
        @issue_categories = issue_categories
        @trackers = trackers
      end

      def trackers
        TrackerSet.new(@trackers)
      end
    end

    class JournalDouble
      attr_reader :id, :user, :created_on, :notes, :private_notes

      def initialize(id:, notes:, user: nil, created_on: nil,
                     private_notes: false, editable: false, visible: true,
                     details: [])
        @id = id
        @notes = notes
        @user = user
        @created_on = created_on
        @private_notes = private_notes
        @editable = editable
        @visible = visible
        @details = details
      end

      def private_notes?
        @private_notes
      end

      # Real: Journal#visible?(user = User.current) - re-checks the issue's
      # visibility only (private notes are filtered separately).
      def visible?(_user = nil)
        @visible
      end

      # Real: Journal#editable_by?(usr) - the user argument is required.
      def editable_by?(_user)
        @editable
      end

      # Real: Journal#visible_details(user = User.current).
      def visible_details(_user = nil)
        @details
      end
    end

    class AttachmentDouble
      attr_reader :id, :filename, :filesize, :content_type, :description,
                  :author, :created_on

      def initialize(id: 1, filename: 'photo.jpg', filesize: 2048,
                     content_type: 'image/jpeg', description: nil,
                     author: nil, created_on: nil, image: true, visible: true,
                     editable: false, deletable: false)
        @id = id
        @filename = filename
        @filesize = filesize
        @content_type = content_type
        @description = description
        @author = author
        @created_on = created_on
        @image = image
        @visible = visible
        @editable = editable
        @deletable = deletable
      end

      def image?
        @image
      end

      # Real: Attachment#visible?/#editable?/#deletable?(user = User.current).
      def visible?(_user = nil)
        @visible
      end

      def editable?(_user = nil)
        @editable
      end

      def deletable?(_user = nil)
        @deletable
      end
    end

    class IssueDouble
      DATA_ATTRS = %i[
        id subject description status tracker project geom lock_version
        updated_on priority author assigned_to category fixed_version
        parent_id start_date due_date done_ratio estimated_hours is_private
        created_on closed_on project_id status_id tracker_id
        journals relations changesets attachments visible_custom_field_values
      ].freeze
      # visible_custom_field_values keeps its writer from attr_accessor; the
      # reader is redefined below with the real model's optional-user arity.

      # State behind the argful RBAC/option readers below, settable only via
      # the constructor (the readers deliberately don't mirror these names).
      CONFIG_ATTRS = %i[
        safe_attribute_names new_statuses_allowed_to
        editable_custom_field_values assignable_users assignable_versions
        deletable notes_addable attachments_addable attributes_editable
      ].freeze

      attr_accessor(*DATA_ATTRS)
      # Reference option sources (no user argument in the real model; they are
      # resolved against the issue's own project/tracker context).
      attr_reader :assignable_users, :assignable_versions

      def initialize(**attrs)
        @journals = []
        @relations = []
        @changesets = []
        @attachments = []
        @visible_custom_field_values = []
        @safe_attribute_names = []
        @new_statuses_allowed_to = []
        @editable_custom_field_values = []
        @assignable_users = []
        @assignable_versions = []
        @deletable = true
        @notes_addable = true
        @attachments_addable = true
        @attributes_editable = true
        attrs.each do |key, value|
          unless DATA_ATTRS.include?(key) || CONFIG_ATTRS.include?(key)
            # Fail loudly on a typo; a silently ignored key would leave the
            # default in place and defeat the point of a typed double.
            raise ArgumentError, "unknown IssueDouble attribute: #{key}"
          end

          instance_variable_set(:"@#{key}", value)
        end
      end

      # The RBAC surface, mirroring the real Issue arities (an optional user
      # argument) so the builders' calls can't drift from the signatures.
      def safe_attribute_names(_user = nil)
        @safe_attribute_names
      end

      # Real: Issue#visible_custom_field_values(user = nil).
      def visible_custom_field_values(_user = nil)
        @visible_custom_field_values
      end

      # Real: Issue#new_statuses_allowed_to(user = User.current,
      # include_default = false). The boolean positional mirrors the real
      # signature on purpose - that fidelity is this double's whole job.
      # rubocop:disable Style/OptionalBooleanParameter
      def new_statuses_allowed_to(_user = nil, _include_default = false)
        # rubocop:enable Style/OptionalBooleanParameter
        @new_statuses_allowed_to
      end

      # Real: Issue#editable_custom_field_values(user = nil).
      def editable_custom_field_values(_user = nil)
        @editable_custom_field_values
      end

      def deletable?(_user = nil)
        @deletable
      end

      def notes_addable?(_user = nil)
        @notes_addable
      end

      def attachments_addable?(_user = nil)
        @attachments_addable
      end

      def attributes_editable?(_user = nil)
        @attributes_editable
      end
    end
  end
end
