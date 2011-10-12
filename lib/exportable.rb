require 'json'
require 'active_record'
require 'RGeo'

module Exportable
  VERSION = '0.1'
  
  def self.included(base)
    base.extend ClassMethods
  end
  
  module ClassMethods
    
    attr_accessor :natural_key_attributes
    attr_accessor :export_options_hash
    attr_accessor :belongs_to_associations_hash
    
    @@GEOMETRY_DATATYPES = %w{GEOMETRY GEOGRAPHY POINT POLYGON LINESTRING MULTIPOLYGON}
    
    def natural_key
      self.natural_key_attributes = get_natural_key if self.natural_key_attributes.nil?
      self.natural_key_attributes
    end
    
    def export_options
      self.export_options_hash = get_export_options if self.export_options_hash.nil?
      self.export_options_hash
    end
    
    def belongs_to_associations
      self.belongs_to_associations_hash = get_belongs_to if self.belongs_to_associations_hash.nil?
      self.belongs_to_associations_hash
    end
    
    def is_association?(name)
      name = name.to_sym if name.is_a?(String)
      self.belongs_to_associations[:association].has_key?(name)
    end
    
    def is_fkey?(attribute)
      attribute = attribute.to_sym if attribute.is_a?(String)
      self.belongs_to_associations[:fkey].has_key?(attribute)
    end
    
    def has_polymorphic_association?
      rv = false
      self.belongs_to_associations[:fkey].each do |key, value|
        rv = true unless self.belongs_to_associations[:fkey][key][:polymorphic].nil?
      end
      return rv
    end
    
    #NOTE:  don't pass the root element
    def upsert! (attribute_hash, skip_attributes = [])
      obj = self.new
      attribute_hash.each do |key,value|
        if is_association?(key)
          info = belongs_to_associations[:association][key.to_sym]
          id = info[:polymorphic].nil? ? find_association(info,value) : find_polymorphic_association(attribute_hash[info[:polymorphic]],value)
          #TODO - If ID is nil we probably need to log an error
          attribute = info[:attribute]
          obj.send("#{attribute}=",id)
        #elsif self.columns_hash[key].sql_type == 'GEOMETRY' || self.columns_hash[key].sql_type == 'POINT'
        elsif @@GEOMETRY_DATATYPES.select { |dt| self.columns_hash[key].sql_type =~ /#{dt}/i }.size > 0
          #hack to get things working with Geospatial
          unless value.nil?
            #geo = Geometry.from_ewkt(value)
            factory = RGeo::Geographic.simple_mercator_factory(:srid => 4326)
            geo = factory.parse_wkt(value)
            obj.send("#{key}=",geo)
          end
        else
          obj.send("#{key}=",value)
        end
      end
     
      #find the record if it already exists, otherwise use the current obj
      conditions = {}
      self.natural_key.each do |key|
        conditions[key.to_sym] = obj.send("#{key}")
      end
      
      model = self.send("find", :first, :conditions => conditions) || obj
      model.update_attributes!(obj.attributes.reject {|attr, value| skip_attributes.include?(attr)})
    end
    
    def get_belongs_to_key (klass)
      options = { :include => {}, :only => [] }
      klass.natural_key.each do |key|
        if klass.is_fkey?(key)
          assoc_hash = klass.belongs_to_associations[:fkey][key]
          assoc_opts = get_belongs_to_key(assoc_hash[:class])
          options[:include][assoc_hash[:name].to_sym] = assoc_opts
        else
          options[:only] << key
        end
      end
      options.keys.each { |opt_key| options.delete(opt_key) if options[opt_key].empty? }
      return options
    end
    
    private
    
    def get_natural_key
      unique_key = self.validators.select { |v| v.kind_of? ActiveRecord::Validations::UniquenessValidator }.first
      return nil if unique_key.nil?
      
      #TODO - validate that validates_uniqueness_of only accepts symbols and not symbols and strings
      rv = []
      rv << unique_key.attributes
      rv << unique_key.options[:scope] if unique_key.options.has_key?(:scope)
      rv.flatten
    end
    
    def get_export_options
      options = {:except => [], :include => {}, :procs => []}
      
      #don't export primary keys
      options[:except] << self.primary_key.to_sym
      
      #add hack for geospatial support
      self.columns_hash.each do |key, value|
        if @@GEOMETRY_DATATYPES.select { |dt| value.sql_type =~ /#{dt}/i }.size > 0
          options[:except] << key.to_sym
          options[:procs] << Proc.new {|options, record| options[:builder].tag!(key, record.send(key).try(:as_text))}
        end
      end
      
      
      #don't export attributes which are belongs_to associations, they are :include(d)
      self.belongs_to_associations[:fkey].each do |attribute, info|
        #skip the association if it is polymorphic - those export options are handled in Exportable::Export.<xml|json>_in_batches, and Exportable::Export.dump_klass_to_<xml|json>
        next unless info[:polymorphic].nil?
        
        klass = info[:class]
        assoc_options = get_belongs_to_key(klass)
        unless assoc_options.nil?
          options[:except] << attribute
          options[:include][info[:name].to_sym] = assoc_options
        end
      end
      options.keys.each { |opt_key| options.delete(opt_key) if options[opt_key].empty? }
      return options
    end
    
    def get_belongs_to
      rv = { :fkey => {}, :association => {}}
      self.reflect_on_all_associations.each do |assoc|
        polymorphic = nil
        association_klass = nil
        next unless assoc.macro == :belongs_to
        association_attribute = assoc.options.has_key?(:foreign_key) ? assoc.options[:foreign_key].to_sym : assoc.name.to_s.concat("_id").to_sym
        if assoc.options.has_key?(:polymorphic)
          association_attribute = assoc.primary_key_name.nil? ? association_attribute : assoc.primary_key_name
          polymorphic = assoc.options[:foreign_type]
        else
          association_klass = assoc.options.has_key?(:class_name) ? assoc.options[:class_name].to_s.classify.constantize : assoc.name.to_s.classify.constantize
        end
        
        #key the belongs_to_assocation two ways; one keyed by the attribute_name, one keyed by the association name
        rv[:fkey][association_attribute] = { :class => association_klass, :name => assoc.name, :attribute => association_attribute, :polymorphic => polymorphic }
        rv[:association][assoc.name] = rv[:fkey][association_attribute]
      end
      return rv
    end
    
    def find_association (association, association_attributes)
      klass = association[:class]
      find_belongs_to_association(klass, association_attributes)
    end
    
    def find_polymorphic_association (association_type, association_attributes)
      klass = association_type.constantize
      find_belongs_to_association(klass, association_attributes)
    end
    
    def find_belongs_to_association (klass, association_attributes)
      conditions = {}
      association_attributes.each do |key, value|
        #only process attributes which are part of the natural key
        next unless (klass.natural_key.include?(key.to_sym) || klass.natural_key.include?("#{key}_id".to_sym))
        
        if klass.is_association?(key.to_sym)
          info = klass.belongs_to_associations[:association][key.to_sym]
          id = find_association(info, value)
          conditions[info[:attribute].to_s] = id
        else
          conditions[key] = value
        end
      end
      obj = klass.send("find", :first, :conditions => conditions)
      obj.nil? ? nil : obj.id
    end
    
  end #ClassMethods
  
  module Exportable::Export
    class << self
      def json_in_batches(klass, options = {})
        proc = lambda { |klass, options| export_options = options.has_key?(:export_options) ? options[:export_options] : klass.export_options; in_batches(klass, options) {|batch| yield batch.to_json(export_options)}}
        process_klass(klass, proc, options)
      end

      def xml_in_batches(klass, options = {})
        proc = lambda { |klass, options| export_options = options.has_key?(:export_options) ? options[:export_options] : klass.export_options; in_batches(klass, options) {|batch| yield batch.to_xml(export_options)}}
        process_klass(klass, proc, options)
      end
    
      private

      def in_batches(klass, options = {})
        batch_size = options.has_key?(:batch_size) ? options[:batch_size] : 500
        conditions = options.has_key?(:find_conditions) ? options[:find_conditions] : {}
        klass.find_in_batches(:batch_size => batch_size, :conditions => conditions) {|batch| yield batch}
      end
    
      def process_klass (klass, proc, options)
        if klass.has_polymorphic_association?
          klass.belongs_to_associations[:association].each do |assoc, info|
            next if info[:polymorphic].nil?
            type = info[:polymorphic]
            assoc_klasses = klass.send("find", :all, :select => "DISTINCT #{type}").collect { |m| m.send("#{type}").constantize }
            assoc_klasses.each do |assoc_klass|
              temp_options = {}
              temp_options[:export_options] = {}
              if (options.has_key?(:include) || options.has_key?(:exclude) || options.has_key?(:procs))
                temp_options[:export_options] = info.clone
              else
                temp_options[:export_options] = klass.export_options
              end
              
              #merge export options
              temp_options[:export_options][:except] = [] unless temp_options[:export_options].has_key?(:except)
              temp_options[:export_options][:except] << info[:attribute].to_sym
              temp_options[:export_options][:except].flatten
              temp_options[:export_options][:include] = {} unless temp_options[:export_options].has_key?(:include)
              temp_options[:export_options][:include][assoc.to_sym] = assoc_klass.get_belongs_to_key(assoc_klass)
              if options.has_key?(:find_conditions)
                find_options = options[:find_conditions][0] + " and #{type} = '#{assoc_klass.to_s}'"
              else
                find_options = ["#{type} = '#{assoc_klass.to_s}'"]
              end
              temp_options[:find_conditions] = find_options
              proc.call(klass, temp_options)
            end
          end
        else #not polymorphic
          proc.call(klass, options)
        end
      end
      
    end
  end #Exportable::Export
  
  module Exportable::Import
    class << self
      
      #allow users to define an error routine for logging bad records
      mattr_accessor :error_routine
      Exportable::Import.error_routine = lambda { |msg, rec| puts "ERROR: #{msg} for record #{rec.inspect}"}
      
      def ingest_json(json_string, skip_attributes = [])
        stats = {:upserted => 0, :rejected => 0}
        json = JSON.parse(json_string)
        if json.is_a?(Array)
          root_elem = json.first.keys.first
          klass = root_elem.camelize.constantize
          json.each do |json_hash|
            begin
              klass.upsert!(json_hash[root_elem], skip_attributes)
              stats[:upserted] += 1
            rescue Exception => e
              error_routine.call(e.message,json_hash[root_elem])
              stats[:rejected] += 1
            end
          end
        else
          root_elem = json.keys.first
          klass = root_elem.camelize.constantize
          begin
            klass.upsert!(json[root_elem], skip_attributes)
            stats[:upserted] += 1
          rescue Exception => e
            error_routine.call(e.message,json[root_elem])
            stats[:rejected] += 1
          end
        end
        return stats
      end

      def ingest_xml(xml, skip_attributes = [])
        xml_hash = Hash.from_xml(xml)
        root_elem = xml_hash.keys.first
        stats = {:upserted => 0, :rejected => 0}

        #does this xml_hash define a single model or multiple model(s)?
        begin
          #try interpretting the hash as a single model
          klass = root_elem.camelize.constantize
          klass.upsert!(xml_hash[root_elem], skip_attributes)
          stats[:upserted] += 1
        rescue NameError
          #try interpretting the hash a multiple model(s)
          klass = root_elem.singularize.camelize.constantize
          xml_hash[root_elem].each do |h|
            begin
              klass.upsert!(h, skip_attributes)
              stats[:upserted] += 1
            rescue Exception => e
              error_routine.call(e.message, h)
              stats[:rejected] += 1
            end
          end
        rescue Exception => e
          error_routine.call(e.message, h)
          stats[:rejected] += 1
        end
        return stats
      end #ingest_xml
      
    end
  end #Exportable::Import
end
