# frozen_string_literal: true
require "bundler/cli/common"

module Bundler
  class CLI::Outdated
    attr_reader :options, :gems
    def initialize(options, gems)
      @options = options
      @gems = gems
    end

    def run
      check_for_deployment_mode

      sources = Array(options[:source])

      gems.each do |gem_name|
        Bundler::CLI::Common.select_spec(gem_name)
      end

      Bundler.definition.validate_runtime!
      current_specs = Bundler.ui.silence { Bundler.load.specs }
      current_dependencies = {}
      Bundler.ui.silence { Bundler.load.dependencies.each {|dep| current_dependencies[dep.name] = dep } }

      definition = if gems.empty? && sources.empty?
        # We're doing a full update
        Bundler.definition(true)
      else
        Bundler.definition(:gems => gems, :sources => sources)
      end

      Bundler.definition.gem_version_promoter.tap do |gvp|
        gvp.level = parse_options_level
        gvp.strict = options[:strict]
      end
      Bundler.load

      definition_resolution = proc { options["local"] ? definition.resolve_with_cache! : definition.resolve_remotely! }
      if options[:parseable]
        Bundler.ui.silence(&definition_resolution)
      else
        definition_resolution.call
      end

      Bundler.ui.info ""
      outdated_gems_by_groups = {}
      outdated_gems_list = []

      # Loop through the current specs
      gemfile_specs, dependency_specs = current_specs.partition {|spec| current_dependencies.key? spec.name }
      [gemfile_specs.sort_by(&:name), dependency_specs.sort_by(&:name)].flatten.each do |current_spec|
        next if !gems.empty? && !gems.include?(current_spec.name)

        dependency = current_dependencies[current_spec.name]
        next if dependency.nil?

        active_spec = Bundler.definition.gem_version_promoter.sort_versions(dependency, definition.index[current_spec.name]).last
        gem_outdated = Gem::Version.new(active_spec.version) > Gem::Version.new(current_spec.version)

        git_outdated = false
        if active_spec.respond_to?(:git_version)
          git_outdated = current_spec.git_version != active_spec.git_version
        end

        if gem_outdated || git_outdated
          groups = nil
          if dependency && !options[:parseable]
            groups = dependency.groups.join(", ")
          end

          outdated_gems_list << { :active_spec => active_spec,
                                  :current_spec => current_spec,
                                  :dependency => dependency,
                                  :groups => groups }

          outdated_gems_by_groups[groups] ||= []
          outdated_gems_by_groups[groups] << { :active_spec => active_spec,
                                               :current_spec => current_spec,
                                               :dependency => dependency,
                                               :groups => groups }
        end

        Bundler.ui.debug "from #{current_spec.loaded_from}"
      end

      if outdated_gems_list.empty?
        Bundler.ui.info "Bundle up to date!\n" unless options[:parseable]
      else
        unless options[:parseable]
          if options["pre"]
            Bundler.ui.info "Outdated gems included in the bundle (including pre-releases):"
          else
            Bundler.ui.info "Outdated gems included in the bundle:"
          end
        end

        if options[:groups] || options[:group]
          ordered_groups = outdated_gems_by_groups.keys.compact.sort
          [nil, ordered_groups].flatten.each do |groups|
            gems = outdated_gems_by_groups[groups]
            contains_group = if groups
              groups.split(",").include?(options[:group])
            else
              options[:group] == "group"
            end

            next if (!options[:groups] && !contains_group) || gems.nil?

            unless options[:parseable]
              if groups
                Bundler.ui.info "===== Group #{groups} ====="
              else
                Bundler.ui.info "===== Without group ====="
              end
            end

            gems.each do |gem|
              print_gem(gem[:current_spec], gem[:active_spec], gem[:dependency], groups)
            end
          end
        else
          outdated_gems_list.each do |gem|
            print_gem(gem[:current_spec], gem[:active_spec], gem[:dependency], gem[:groups])
          end
        end

        exit 1
      end
    end

  private

    def parse_options_level
      return :minor if options[:minor]
      return :patch if options[:patch]

      :major
    end

    def print_gem(current_spec, active_spec, dependency, groups)
      spec_version = if active_spec.respond_to?(:git_version)
        "#{active_spec.version}#{active_spec.git_version}"
      else
        active_spec.version.to_s
      end

      current_version = "#{current_spec.version}#{current_spec.git_version}"
      dependency_version = %(, requested #{dependency.requirement}) if dependency && dependency.specific?

      spec_outdated_info = "#{active_spec.name} (newest #{spec_version}, installed #{current_version}#{dependency_version})"
      if options[:parseable]
        Bundler.ui.info spec_outdated_info.to_s.rstrip
      elsif options[:groups] || !groups
        Bundler.ui.info "  * #{spec_outdated_info}".rstrip
      else
        Bundler.ui.info "  * #{spec_outdated_info} in groups \"#{groups}\"".rstrip
      end
    end

    def check_for_deployment_mode
      if Bundler.settings[:frozen]
        error_message = "You are trying to check outdated gems in deployment mode. " \
              "Run `bundle outdated` elsewhere.\n" \
              "\nIf this is a development machine, remove the #{Bundler.default_gemfile} freeze" \
              "\nby running `bundle install --no-deployment`."
        raise ProductionError, error_message
      end
    end
  end
end
