# frozen_string_literal: true

module RedmineGttSync
  # Query-driven generalization of ProjectBundle: materialize the issues of any
  # saved Redmine query (project-scoped or global/cross-project) as one payload.
  # A project load is just the special case `query = {project filter}`.
  #
  # Unlike ProjectBundle there is no single project, so the payload carries a
  # `projects` directory and a `project_boundary` FeatureCollection covering
  # *every* project represented in the result (0..N), and each issue carries its
  # `project_id`.
  #
  # This module only SHAPES records. The controller passes issues already scoped
  # to both the query's visibility (view_issues) AND the per-project
  # `use_gtt_sync` gate, so the endpoint never widens access.
  module QueryBundle
    module_function

    # +issues+ must already be visibility- and use_gtt_sync-scoped; +user+ is
    # the acting user the per-feature editable flag is resolved for.
    def build(issues, base_url:, user:)
      base = base_url.to_s.chomp('/')
      grouped = { 'point' => [], 'line' => [], 'polygon' => [] }
      unplaced = []

      issues.each do |issue|
        geojson = issue.geom && Geometry.to_geojson(issue.geom)
        category = geojson && ProjectBundle::GEOMETRY_CATEGORY[geojson['type']]
        if category
          grouped[category] << ProjectBundle.feature(issue, geojson, user)
        else
          unplaced << ProjectBundle.summary(issue, user)
        end
      end

      projects = issues.map(&:project).uniq
      {
        'issues' => {
          'point' => ProjectBundle.collection(grouped['point']),
          'line' => ProjectBundle.collection(grouped['line']),
          'polygon' => ProjectBundle.collection(grouped['polygon']),
          'unplaced' => unplaced
        },
        'project_boundary' => boundaries(projects),
        'projects' => projects.map { |project| project_dir(project, base) }
      }
    end

    # Boundaries of the involved projects that have geometry, each tagged with
    # its project so a multi-project boundary layer stays attributable.
    def boundaries(projects)
      features = projects.select(&:geom).map do |project|
        {
          'type' => 'Feature',
          'geometry' => Geometry.to_geojson(project.geom),
          'properties' => {
            'project_id' => project.id,
            'identifier' => project.identifier,
            'name' => project.name
          }
        }
      end
      { 'type' => 'FeatureCollection', 'features' => features }
    end

    def project_dir(project, base)
      {
        '@id' => "#{base}/projects/#{project.identifier}",
        'id' => project.id,
        'identifier' => project.identifier,
        'name' => project.name,
        'has_boundary' => !project.geom.nil?
      }
    end
  end
end
