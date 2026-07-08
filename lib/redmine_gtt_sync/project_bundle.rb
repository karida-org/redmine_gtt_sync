module RedmineGttSync
  # Optimized, QTask-shaped payload for a whole project in one call: issues split
  # by geometry type (point/line/polygon) plus the geometry-less "unplaced" ones,
  # and the project boundary. Saves a client stitching together issues.geojson +
  # projects/:id.geojson + gtt/settings.json, and surfaces the unplaced issues
  # that issues.geojson omits (for the set-geometry-later workflow).
  #
  # This module only SHAPES records; the controller is responsible for passing
  # already permission-scoped inputs (Project.visible / Issue.visible), so the
  # endpoint never widens what the user can see.
  module ProjectBundle
    GEOMETRY_CATEGORY = {
      'Point' => 'point', 'MultiPoint' => 'point',
      'LineString' => 'line', 'MultiLineString' => 'line',
      'Polygon' => 'polygon', 'MultiPolygon' => 'polygon'
    }.freeze

    module_function

    # +issues+ must already be visibility-scoped (e.g. project.issues.visible).
    def build(project, issues, base_url:)
      base = base_url.to_s.chomp('/')
      grouped = { 'point' => [], 'line' => [], 'polygon' => [] }
      unplaced = []

      issues.each do |issue|
        geojson = issue.geom && Geometry.to_geojson(issue.geom)
        category = geojson && GEOMETRY_CATEGORY[geojson['type']]
        if category
          grouped[category] << feature(issue, geojson)
        else
          unplaced << summary(issue)
        end
      end

      {
        'project' => project_info(project, base),
        'issues' => {
          'point' => collection(grouped['point']),
          'line' => collection(grouped['line']),
          'polygon' => collection(grouped['polygon']),
          'unplaced' => unplaced
        }
      }
    end

    def feature(issue, geojson)
      {
        'type' => 'Feature',
        'id' => issue.id,
        'geometry' => geojson,
        'properties' => summary(issue)
      }
    end

    # ID-based properties, matching the shape GTT's issues.geojson emits.
    # `project_id` lets a cross-project (query) result render and route writes to
    # the right project; it is harmless in the single-project bundle too.
    #
    # `custom_fields` carries the issue's visible custom-field values (same shape
    # as the single issue document) so the whole loaded set - and an offline
    # package built from it - has them without an N+1 per-issue fetch. The client
    # writes them to a related table, not flat columns (applicability and
    # multi-value don't fit a uniform schema).
    #
    # priority/assigned_to/category/fixed_version are sent as display NAMES (not
    # ids like status/tracker): the client resolves status and tracker via gtt
    # settings for their colour/icon, but has no client-side lookup for these and
    # the issue list only needs a label. start_date/due_date/done_ratio/
    # estimated_hours and the created_on/updated_on timestamps are literals (ISO
    # for dates/times) so they render and sort directly as optional list columns.
    # All are optional on the client, so an older server that omits them just
    # leaves those columns blank. The reference associations are preloaded in the
    # controller (preload_issue_associations) to keep a large bundle from fanning
    # out into per-issue N+1 lookups.
    def summary(issue)
      {
        'id' => issue.id,
        'project_id' => issue.project_id,
        'subject' => issue.subject,
        'status_id' => issue.status_id,
        'tracker_id' => issue.tracker_id,
        'priority' => issue.priority&.name,
        'assigned_to' => issue.assigned_to&.name,
        'category' => issue.category&.name,
        'fixed_version' => issue.fixed_version&.name,
        'start_date' => issue.start_date&.iso8601,
        'due_date' => issue.due_date&.iso8601,
        'done_ratio' => issue.done_ratio,
        'estimated_hours' => issue.estimated_hours,
        'created_on' => issue.created_on&.iso8601,
        'updated_on' => issue.updated_on&.iso8601,
        'lock_version' => issue.lock_version,
        'custom_fields' => CustomFields.values(issue)
      }
    end

    def collection(features)
      { 'type' => 'FeatureCollection', 'features' => features }
    end

    def project_info(project, base)
      {
        '@id' => "#{base}/projects/#{project.identifier}",
        'id' => project.id,
        'identifier' => project.identifier,
        'name' => project.name,
        'boundary' => boundary_feature(project)
      }
    end

    def boundary_feature(project)
      return nil unless project.geom

      { 'type' => 'Feature', 'geometry' => Geometry.to_geojson(project.geom), 'properties' => {} }
    end
  end
end
