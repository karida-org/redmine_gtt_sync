module RedmineGttSync
  # A single issue as a JSON-LD document: a portable, linked-data representation
  # anchored by the issue's canonical IRI (@id), carrying geometry as both
  # GeoJSON and EWKT. This is the identity foundation the client and the
  # portable-issue / connection-manager features resolve against: the IRI is the
  # issue's global name, independent of transport.
  module IssueDocument
    # Inline JSON-LD context: schema.org for the issue vocabulary, GeoSPARQL for
    # the WKT literal, GeoJSON-LD for the geometry term. Inlined (not a hosted
    # URL) so the document is self-contained and needs no network to interpret.
    CONTEXT = {
      '@vocab' => 'https://schema.org/',
      'gtt' => 'https://karida.info/ns/gtt#',
      'geo' => 'http://www.opengis.net/ont/geosparql#',
      'geojson' => 'https://purl.org/geojson/vocab#',
      'geometry' => 'geojson:geometry',
      'asWKT' => { '@id' => 'geo:asWKT', '@type' => 'geo:wktLiteral' }
    }.freeze

    module_function

    # Build the JSON-LD hash for +issue+. +base_url+ is the instance origin
    # (e.g. "https://example.com"); IRIs are built from it so they match the
    # instance's canonical addresses regardless of the request host.
    def build(issue, base_url:)
      base = base_url.to_s.chomp('/')
      geom = issue.geom
      {
        '@context' => CONTEXT,
        '@id' => "#{base}/issues/#{issue.id}",
        '@type' => 'gtt:Issue',
        'identifier' => issue.id,
        'subject' => issue.subject,
        'description' => issue.description.presence,
        'status' => reference(base, 'issue_statuses', issue.status),
        'tracker' => reference(base, 'trackers', issue.tracker),
        'project' => project_reference(base, issue.project),
        'geometry' => Geometry.to_geojson(geom),
        'asWKT' => Geometry.to_ewkt(geom),
        'lock_version' => issue.lock_version,
        'updated_on' => issue.updated_on&.iso8601
      }.compact
    end

    def reference(base, path, record)
      return nil if record.nil?

      { '@id' => "#{base}/#{path}/#{record.id}", 'id' => record.id, 'name' => record.name }
    end

    def project_reference(base, project)
      return nil if project.nil?

      {
        '@id' => "#{base}/projects/#{project.identifier}",
        'id' => project.id,
        'identifier' => project.identifier,
        'name' => project.name
      }
    end
  end
end
