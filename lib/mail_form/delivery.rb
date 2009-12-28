module MailForm::Delivery
  extend ActiveSupport::Concern

  ACCESSORS = [ :mail_attributes, :mail_subject, :mail_captcha,
                :mail_attachments, :mail_recipients, :mail_sender,
                :mail_headers, :mail_template, :mail_appendable ]

  included do
    class_inheritable_reader *ACCESSORS
    protected *ACCESSORS

    # Initialize arrays and hashes
    write_inheritable_array :mail_captcha, []
    write_inheritable_array :mail_appendable, []
    write_inheritable_array :mail_attributes, []
    write_inheritable_array :mail_attachments, []

    headers({})
    sender {|c| c.email }
    subject{|c| c.class.model_name.human }
    template 'default'

    before_create :not_spam?
    after_create  :deliver!

    attr_accessor :request
    alias :deliver :create
  end

  module ClassMethods
    # Declare your form attributes. All attributes declared here will be appended
    # to the e-mail, except the ones captcha is true.
    #
    # == Options
    #
    # * :validate - A hook to validates_*_of. When true is given, validates the
    #       presence of the attribute. When a regexp, validates format. When array,
    #       validates the inclusion of the attribute in the array.
    # 
    #       Whenever :validate is given, the presence is automatically checked. Give
    #       :allow_blank => true to override.
    # 
    #       Finally, when :validate is a symbol, the method given as symbol will be
    #       called. Then you can add validations as you do in ActiveRecord (errors.add).
    #
    # * <tt>:attachment</tt> - When given, expects a file to be sent and attaches
    #   it to the e-mail. Don't forget to set your form to multitype.
    #
    # * <tt>:captcha</tt> - When true, validates the attributes must be blank
    #   This is a simple way to avoid spam
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     attributes :name,  :validate => true
    #     attributes :email, :validate => /^([^@]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i
    #     attributes :type,  :validate => ["General", "Interface bug"]
    #     attributes :message
    #     attributes :screenshot, :attachment => true, :validate => :interface_bug?
    #     attributes :nickname, :captcha => true
    #
    #     def interface_bug?
    #       if type == 'Interface bug' && screenshot.nil?
    #         self.errors.add(:screenshot, "can't be blank when you are reporting an interface bug")
    #       end
    #     end
    #   end
    #
    def attribute(*accessors)
      options = accessors.extract_options!
      attr_accessor *(accessors - instance_methods.map(&:to_sym))

      if options[:attachment]
        write_inheritable_array(:mail_attachments, accessors)
      elsif options[:captcha]
        write_inheritable_array(:mail_captcha, accessors)
      else
        write_inheritable_array(:mail_attributes, accessors)
      end

      validation = options.delete(:validate)
      return unless validation

      accessors.each do |accessor|
        case validation
        when Symbol, Class
          validate validation
          break
        when Regexp
          validates_format_of accessor, :with => validation, :allow_blank => true
        when Array
          validates_inclusion_of accessor, :in => validation, :allow_blank => true
        when Range
          validates_length_of accessor, :within => validation, :allow_blank => true
        end

        validates_presence_of accessor unless options[:allow_blank] == true
      end
    end
    alias :attributes :attribute

    # Declares contact email sender. It can be a string or a proc or a symbol.
    #
    # When a symbol is given, it will call a method on the form object with
    # the same name as the symbol. As a proc, it receives a simple form
    # instance. By default is the class human name.
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     subject "My Contact Form"
    #   end
    #
    def subject(duck=nil, &block)
      write_inheritable_attribute(:mail_subject, duck || block)
    end

    # Declares contact email sender. It can be a string or a proc or a symbol.
    #
    # When a symbol is given, it will call a method on the form object with
    # the same name as the symbol. As a proc, it receives a simple form
    # instance. By default is:
    #
    #   sender{ |c| c.email }
    #
    # This requires that your MailForm object have an email attribute.
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     # Change sender to include also the name
    #     sender { |c| %{"#{c.name}" <#{c.email}>} }
    #   end
    #
    def sender(duck=nil, &block)
      write_inheritable_attribute(:mail_sender, duck || block)
    end
    alias :from :sender

    # Who will receive the e-mail. Can be a string or array or a symbol or a proc.
    #
    # When a symbol is given, it will call a method on the form object with
    # the same name as the symbol. As a proc, it receives a simple form instance.
    #
    # Both the proc and the symbol must return a string or an array. By default
    # is nil.
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     recipients [ "first.manager@domain.com", "second.manager@domain.com" ]
    #   end
    #
    def recipients(duck=nil, &block)
      write_inheritable_attribute(:mail_recipients, duck || block)
    end
    alias :to :recipients

    # Additional headers to your e-mail.
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     headers { :content_type => 'text/html' }
    #   end
    #
    def headers(hash)
      write_inheritable_hash(:mail_headers, hash)
    end

    # Customized template for your e-mail, if you don't want to use default
    # 'contact' template or need more than one contact form with different
    # template layouts.
    #
    # When a symbol is given, it will call a method on the form object with
    # the same name as the symbol. As a proc, it receives a simple form
    # instance. Both method and proc must return a string with the template
    # name. Defaults to 'contact'.
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     # look for a template in views/mail_form/notifier/my_template.erb
    #     template 'my_template'
    #   end
    #
    def template(new_template)
      write_inheritable_attribute(:mail_template, new_template)
    end

    # Values from request object to be appended to the contact form.
    # Whenever used, you have to send the request object when initializing the object:
    #
    #   @contact_form = ContactForm.new(params[:contact_form], request)
    #
    # You can get the values to be appended from the AbstractRequest
    # documentation (http://api.rubyonrails.org/classes/ActionController/AbstractRequest.html)
    #
    # == Examples
    #
    #   class ContactForm < MailForm
    #     append :remote_ip, :user_agent, :session, :cookies
    #   end
    #
    def append(*values)
      write_inheritable_array(:mail_appendable, values)
    end
  end

  # In development, raises an error if the captcha field is not blank. This is
  # is good to remember that the field should be hidden with CSS and shown only
  # to robots.
  #
  # In test and in production, it returns true if all captcha fields are blank,
  # returns false otherwise.
  #
  def spam?
    mail_captcha.each do |field|
      next if send(field).blank?

      if RAILS_ENV == 'development'
        raise ScriptError, "The captcha field #{field} was supposed to be blank"
      else
        return true
      end
    end

    false
  end

  def not_spam?
    !spam?
  end

  # Deliver the resource without checking any condition.
  def deliver!
    MailForm.deliver_default(self)
  end
end