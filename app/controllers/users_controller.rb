class UsersController < ApplicationController
  layout "site"

  skip_before_action :verify_authenticity_token, :only => [:auth_success]
  before_action :disable_terms_redirect, :only => [:terms, :save, :logout]
  before_action :authorize_web
  before_action :set_locale
  before_action :check_database_readable

  authorize_resource

  before_action :require_self, :only => [:account]
  before_action :check_database_writable, :only => [:new, :account, :confirm, :confirm_email, :lost_password, :reset_password, :go_public]
  before_action :require_cookies, :only => [:new, :login, :confirm]
  before_action :lookup_user_by_name, :only => [:set_status, :destroy]
  before_action :allow_thirdparty_images, :only => [:show, :account]

  def terms
    @legale = params[:legale] || OSM.ip_to_country(request.remote_ip) || Settings.default_legale
    @text = OSM.legal_text_for_country(@legale)

    if request.xhr?
      render :partial => "terms"
    else
      @title = t "users.terms.title"

      if current_user&.terms_agreed?
        # Already agreed to terms, so just show settings
        redirect_to :action => :account, :display_name => current_user.display_name
      elsif current_user.nil? && session[:new_user].nil?
        redirect_to :action => :login, :referer => request.fullpath
      end
    end
  end

  def save
    @title = t "users.new.title"

    if params[:decline] || !(params[:read_tou] && params[:read_ct])
      if current_user
        current_user.terms_seen = true

        flash[:notice] = t("users.new.terms declined", :url => t("users.new.terms declined url")).html_safe if current_user.save

        if params[:referer]
          redirect_to safe_referer(params[:referer])
        else
          redirect_to :action => :account, :display_name => current_user.display_name
        end
      elsif params[:decline]
        redirect_to t("users.terms.declined")
      else
        redirect_to :action => :terms
      end
    elsif current_user
      unless current_user.terms_agreed?
        current_user.consider_pd = params[:user][:consider_pd]
        current_user.tou_agreed = Time.now.getutc
        current_user.terms_agreed = Time.now.getutc
        current_user.terms_seen = true

        flash[:notice] = t "users.new.terms accepted" if current_user.save
      end

      if params[:referer]
        redirect_to safe_referer(params[:referer])
      else
        redirect_to :action => :account, :display_name => current_user.display_name
      end
    else
      self.current_user = session.delete(:new_user)

      if check_signup_allowed(current_user.email)
        current_user.data_public = true
        current_user.description = "" if current_user.description.nil?
        current_user.creation_ip = request.remote_ip
        current_user.languages = http_accept_language.user_preferred_languages
        current_user.terms_agreed = Time.now.getutc
        current_user.tou_agreed = Time.now.getutc
        current_user.terms_seen = true

        if current_user.auth_uid.blank?
          current_user.auth_provider = nil
          current_user.auth_uid = nil
        end

        if current_user.save
          flash[:piwik_goal] = PIWIK["goals"]["signup"] if defined?(PIWIK)

          referer = welcome_path

          begin
            uri = URI(session[:referer])
            %r{map=(.*)/(.*)/(.*)}.match(uri.fragment) do |m|
              editor = Rack::Utils.parse_query(uri.query).slice("editor")
              referer = welcome_path({ "zoom" => m[1],
                                       "lat" => m[2],
                                       "lon" => m[3] }.merge(editor))
            end
          rescue StandardError
            # Use default
          end

          if current_user.status == "active"
            session[:referer] = referer
            successful_login(current_user)
          else
            session[:token] = current_user.tokens.create.token
            UserMailer.signup_confirm(current_user, current_user.tokens.create(:referer => referer)).deliver_later
            redirect_to :action => "confirm", :display_name => current_user.display_name
          end
        else
          render :action => "new", :referer => params[:referer]
        end
      end
    end
  end

  def account
    @tokens = current_user.oauth_tokens.authorized

    append_content_security_policy_directives(
      :form_action => %w[accounts.google.com *.facebook.com login.live.com github.com meta.wikimedia.org]
    )

    if request.post?
      if params[:user][:auth_provider].blank? ||
         (params[:user][:auth_provider] == current_user.auth_provider &&
          params[:user][:auth_uid] == current_user.auth_uid)
        update_user(current_user, params)
        redirect_to user_account_url(current_user) if current_user.errors.count.zero?
      else
        session[:new_user_settings] = params
        redirect_to auth_url(params[:user][:auth_provider], params[:user][:auth_uid]), :status => :temporary_redirect
      end
    elsif errors = session.delete(:user_errors)
      errors.each do |attribute, error|
        current_user.errors.add(attribute, error)
      end
    end
    @title = t "users.account.title"
  end

  def go_public
    current_user.data_public = true
    current_user.save
    flash[:notice] = t "users.go_public.flash success"
    redirect_to :action => "account", :display_name => current_user.display_name
  end

  def lost_password
    @title = t "users.lost_password.title"

    if request.post?
      user = User.visible.find_by(:email => params[:email])

      if user.nil?
        users = User.visible.where("LOWER(email) = LOWER(?)", params[:email])

        user = users.first if users.count == 1
      end

      if user
        token = user.tokens.create
        UserMailer.lost_password(user, token).deliver_later
        flash[:notice] = t "users.lost_password.notice email on way"
        redirect_to login_path
      else
        flash.now[:error] = t "users.lost_password.notice email cannot find"
      end
    end
  end

  def reset_password
    @title = t "users.reset_password.title"

    if params[:token]
      token = UserToken.find_by(:token => params[:token])

      if token
        self.current_user = token.user

        if params[:user]
          current_user.pass_crypt = params[:user][:pass_crypt]
          current_user.pass_crypt_confirmation = params[:user][:pass_crypt_confirmation]
          current_user.status = "active" if current_user.status == "pending"
          current_user.email_valid = true

          if current_user.save
            token.destroy
            session[:fingerprint] = current_user.fingerprint
            flash[:notice] = t "users.reset_password.flash changed"
            successful_login(current_user)
          end
        end
      else
        flash[:error] = t "users.reset_password.flash token bad"
        redirect_to :action => "lost_password"
      end
    else
      head :bad_request
    end
  end

  def new
    @title = t "users.new.title"
    @referer = if params[:referer]
                 safe_referer(params[:referer])
               else
                 session[:referer]
               end

    append_content_security_policy_directives(
      :form_action => %w[accounts.google.com *.facebook.com login.live.com github.com meta.wikimedia.org]
    )

    if current_user
      # The user is logged in already, so don't show them the signup
      # page, instead send them to the home page
      if @referer
        redirect_to @referer
      else
        redirect_to :controller => "site", :action => "index"
      end
    elsif params.key?(:auth_provider) && params.key?(:auth_uid)
      self.current_user = User.new(:email => params[:email],
                                   :email_confirmation => params[:email],
                                   :display_name => params[:nickname],
                                   :auth_provider => params[:auth_provider],
                                   :auth_uid => params[:auth_uid])

      flash.now[:notice] = render_to_string :partial => "auth_association"
    else
      check_signup_allowed

      self.current_user = User.new
    end
  end

  def create
    self.current_user = User.new(user_params)

    if check_signup_allowed(current_user.email)
      session[:referer] = safe_referer(params[:referer]) if params[:referer]

      Rails.logger.info "create: #{session[:referer]}"

      current_user.status = "pending"

      if current_user.auth_provider.present? && current_user.pass_crypt.empty?
        # We are creating an account with external authentication and
        # no password was specified so create a random one
        current_user.pass_crypt = SecureRandom.base64(16)
        current_user.pass_crypt_confirmation = current_user.pass_crypt
      end

      if current_user.invalid?
        # Something is wrong with a new user, so rerender the form
        render :action => "new"
      elsif current_user.auth_provider.present?
        # Verify external authenticator before moving on
        session[:new_user] = current_user
        redirect_to auth_url(current_user.auth_provider, current_user.auth_uid), :status => :temporary_redirect
      else
        # Save the user record
        session[:new_user] = current_user
        redirect_to :action => :terms
      end
    end
  end

  def login
    append_content_security_policy_directives(
      :form_action => %w[*]
    )

    session[:referer] = safe_referer(params[:referer]) if params[:referer]

    if request.post?
      session[:remember_me] ||= params[:remember_me]
      password_authentication(params[:username], params[:password])
    end
  end

  def logout
    @title = t "users.logout.title"

    if request.post?
      if session[:token]
        token = UserToken.find_by(:token => session[:token])
        token&.destroy
        session.delete(:token)
      end
      session.delete(:user)
      session_expires_automatically
      if params[:referer]
        redirect_to safe_referer(params[:referer])
      else
        redirect_to :controller => "site", :action => "index"
      end
    end
  end

  def confirm
    if request.post?
      token = UserToken.find_by(:token => params[:confirm_string])
      if token&.user&.active?
        flash[:error] = t("users.confirm.already active")
        redirect_to login_path
      elsif !token || token.expired?
        flash[:error] = t("users.confirm.unknown token")
        redirect_to :action => "confirm"
      else
        user = token.user
        user.status = "active"
        user.email_valid = true
        flash[:notice] = gravatar_status_message(user) if gravatar_enable(user)
        user.save!
        referer = safe_referer(token.referer) if token.referer
        token.destroy

        if session[:token]
          token = UserToken.find_by(:token => session[:token])
          session.delete(:token)
        else
          token = nil
        end

        if token.nil? || token.user != user
          flash[:notice] = t("users.confirm.success")
          redirect_to login_path(:referer => referer)
        else
          token.destroy

          session[:user] = user.id
          session[:fingerprint] = user.fingerprint

          redirect_to referer || welcome_path
        end
      end
    else
      user = User.find_by(:display_name => params[:display_name])

      redirect_to root_path if user.nil? || user.active?
    end
  end

  def confirm_resend
    user = User.find_by(:display_name => params[:display_name])
    token = UserToken.find_by(:token => session[:token])

    if user.nil? || token.nil? || token.user != user
      flash[:error] = t "users.confirm_resend.failure", :name => params[:display_name]
    else
      UserMailer.signup_confirm(user, user.tokens.create).deliver_later
      flash[:notice] = t "users.confirm_resend.success_html", :email => user.email, :sender => Settings.support_email
    end

    redirect_to login_path
  end

  def confirm_email
    if request.post?
      token = UserToken.find_by(:token => params[:confirm_string])
      if token&.user&.new_email?
        self.current_user = token.user
        current_user.email = current_user.new_email
        current_user.new_email = nil
        current_user.email_valid = true
        gravatar_enabled = gravatar_enable(current_user)
        if current_user.save
          flash[:notice] = if gravatar_enabled
                             "#{t('users.confirm_email.success')} #{gravatar_status_message(current_user)}"
                           else
                             t("users.confirm_email.success")
                           end
        else
          flash[:errors] = current_user.errors
        end
        current_user.tokens.delete_all
        session[:user] = current_user.id
        session[:fingerprint] = current_user.fingerprint
        redirect_to :action => "account", :display_name => current_user.display_name
      elsif token
        flash[:error] = t "users.confirm_email.failure"
        redirect_to :action => "account", :display_name => token.user.display_name
      else
        flash[:error] = t "users.confirm_email.unknown_token"
      end
    end
  end

  def show
    @user = User.find_by(:display_name => params[:display_name])

    if @user &&
       (@user.visible? || current_user&.administrator?)
      @title = @user.display_name
    else
      render_unknown_user params[:display_name]
    end
  end

  ##
  # sets a user's status
  def set_status
    @user.status = params[:status]
    @user.save
    redirect_to user_path(:display_name => params[:display_name])
  end

  ##
  # delete a user, marking them as deleted and removing personal data
  def destroy
    @user.delete
    redirect_to user_path(:display_name => params[:display_name])
  end

  ##
  # display a list of users matching specified criteria
  def index
    if request.post?
      ids = params[:user].keys.collect(&:to_i)

      User.where(:id => ids).update_all(:status => "confirmed") if params[:confirm]
      User.where(:id => ids).update_all(:status => "deleted") if params[:hide]

      redirect_to url_for(:status => params[:status], :ip => params[:ip], :page => params[:page])
    else
      @params = params.permit(:status, :ip)

      conditions = {}
      conditions[:status] = @params[:status] if @params[:status]
      conditions[:creation_ip] = @params[:ip] if @params[:ip]

      @user_pages, @users = paginate(:users,
                                     :conditions => conditions,
                                     :order => :id,
                                     :per_page => 50)
    end
  end

  ##
  # omniauth success callback
  def auth_success
    auth_info = request.env["omniauth.auth"]

    provider = auth_info[:provider]
    uid = auth_info[:uid]
    name = auth_info[:info][:name]
    email = auth_info[:info][:email]

    case provider
    when "openid"
      email_verified = uid.match(%r{https://www.google.com/accounts/o8/id?(.*)}) ||
                       uid.match(%r{https://me.yahoo.com/(.*)})
    when "google", "facebook"
      email_verified = true
    else
      email_verified = false
    end

    if settings = session.delete(:new_user_settings)
      current_user.auth_provider = provider
      current_user.auth_uid = uid

      update_user(current_user, settings)

      flash.discard

      session[:user_errors] = current_user.errors.as_json

      redirect_to :action => "account", :display_name => current_user.display_name
    elsif session[:new_user]
      session[:new_user].auth_provider = provider
      session[:new_user].auth_uid = uid

      session[:new_user].status = "active" if email_verified && email == session[:new_user].email

      redirect_to :action => "terms"
    else
      user = User.find_by(:auth_provider => provider, :auth_uid => uid)

      if user.nil? && provider == "google"
        openid_url = auth_info[:extra][:id_info]["openid_id"]
        user = User.find_by(:auth_provider => "openid", :auth_uid => openid_url) if openid_url
        user&.update(:auth_provider => provider, :auth_uid => uid)
      end

      if user
        case user.status
        when "pending"
          unconfirmed_login(user)
        when "active", "confirmed"
          successful_login(user, request.env["omniauth.params"]["referer"])
        when "suspended"
          failed_login t("users.login.account is suspended", :webmaster => "mailto:#{Settings.support_email}").html_safe
        else
          failed_login t("users.login.auth failure")
        end
      else
        redirect_to :action => "new", :nickname => name, :email => email,
                    :auth_provider => provider, :auth_uid => uid
      end
    end
  end

  ##
  # omniauth failure callback
  def auth_failure
    flash[:error] = t("users.auth_failure.#{params[:message]}")
    redirect_to params[:origin] || login_url
  end

  private

  ##
  # handle password authentication
  def password_authentication(username, password)
    if user = User.authenticate(:username => username, :password => password)
      successful_login(user)
    elsif user = User.authenticate(:username => username, :password => password, :pending => true)
      unconfirmed_login(user)
    elsif User.authenticate(:username => username, :password => password, :suspended => true)
      failed_login t("users.login.account is suspended", :webmaster => "mailto:#{Settings.support_email}").html_safe, username
    else
      failed_login t("users.login.auth failure"), username
    end
  end

  ##
  # return the URL to use for authentication
  def auth_url(provider, uid, referer = nil)
    params = { :provider => provider }

    params[:openid_url] = openid_expand_url(uid) if provider == "openid"

    if referer.nil?
      params[:origin] = request.path
    else
      params[:origin] = "#{request.path}?referer=#{CGI.escape(referer)}"
      params[:referer] = referer
    end

    auth_path(params)
  end

  ##
  # special case some common OpenID providers by applying heuristics to
  # try and come up with the correct URL based on what the user entered
  def openid_expand_url(openid_url)
    if openid_url.nil?
      nil
    elsif openid_url.match(%r{(.*)gmail.com(/?)$}) || openid_url.match(%r{(.*)googlemail.com(/?)$})
      # Special case gmail.com as it is potentially a popular OpenID
      # provider and, unlike yahoo.com, where it works automatically, Google
      # have hidden their OpenID endpoint somewhere obscure this making it
      # somewhat less user friendly.
      "https://www.google.com/accounts/o8/id"
    else
      openid_url
    end
  end

  ##
  # process a successful login
  def successful_login(user, referer = nil)
    session[:user] = user.id
    session[:fingerprint] = user.fingerprint
    session_expires_after 28.days if session[:remember_me]

    target = referer || session[:referer] || url_for(:controller => :site, :action => :index)

    # The user is logged in, so decide where to send them:
    #
    # - If they haven't seen the contributor terms, send them there.
    # - If they have a block on them, show them that.
    # - If they were referred to the login, send them back there.
    # - Otherwise, send them to the home page.
    if !user.terms_seen
      redirect_to :action => :terms, :referer => target
    elsif user.blocked_on_view
      redirect_to user.blocked_on_view, :referer => target
    else
      redirect_to target
    end

    session.delete(:remember_me)
    session.delete(:referer)
  end

  ##
  # process a failed login
  def failed_login(message, username = nil)
    flash[:error] = message

    redirect_to :action => "login", :referer => session[:referer],
                :username => username, :remember_me => session[:remember_me]

    session.delete(:remember_me)
    session.delete(:referer)
  end

  ##
  #
  def unconfirmed_login(user)
    session[:token] = user.tokens.create.token

    redirect_to :action => "confirm", :display_name => user.display_name

    session.delete(:remember_me)
    session.delete(:referer)
  end

  ##
  # update a user's details
  def update_user(user, params)
    user.display_name = params[:user][:display_name]
    user.new_email = params[:user][:new_email]

    unless params[:user][:pass_crypt].empty? && params[:user][:pass_crypt_confirmation].empty?
      user.pass_crypt = params[:user][:pass_crypt]
      user.pass_crypt_confirmation = params[:user][:pass_crypt_confirmation]
    end

    if params[:user][:description] != user.description
      user.description = params[:user][:description]
      user.description_format = "markdown"
    end

    user.languages = params[:user][:languages].split(",")

    case params[:avatar_action]
    when "new"
      user.avatar.attach(params[:user][:avatar])
      user.image_use_gravatar = false
    when "delete"
      user.avatar.purge_later
      user.image_use_gravatar = false
    when "gravatar"
      user.avatar.purge_later
      user.image_use_gravatar = true
    end

    user.home_lat = params[:user][:home_lat]
    user.home_lon = params[:user][:home_lon]

    user.preferred_editor = if params[:user][:preferred_editor] == "default"
                              nil
                            else
                              params[:user][:preferred_editor]
                            end

    if params[:user][:auth_provider].nil? || params[:user][:auth_provider].blank?
      user.auth_provider = nil
      user.auth_uid = nil
    end

    if user.save
      session[:fingerprint] = user.fingerprint

      set_locale(:reset => true)

      if user.new_email.blank? || user.new_email == user.email
        flash[:notice] = t "users.account.flash update success"
      else
        user.email = user.new_email

        if user.valid?
          flash[:notice] = t "users.account.flash update success confirm needed"

          begin
            UserMailer.email_confirm(user, user.tokens.create).deliver_later
          rescue StandardError
            # Ignore errors sending email
          end
        else
          current_user.errors.add(:new_email, current_user.errors[:email])
          current_user.errors.add(:email, [])
        end

        user.restore_email!
      end
    end
  end

  ##
  # require that the user in the URL is the logged in user
  def require_self
    head :forbidden if params[:display_name] != current_user.display_name
  end

  ##
  # ensure that there is a "user" instance variable
  def lookup_user_by_name
    @user = User.find_by(:display_name => params[:display_name])
  rescue ActiveRecord::RecordNotFound
    redirect_to :action => "view", :display_name => params[:display_name] unless @user
  end

  ##
  #
  def disable_terms_redirect
    # this is necessary otherwise going to the user terms page, when
    # having not agreed already would cause an infinite redirect loop.
    # it's .now so that this doesn't propagate to other pages.
    flash.now[:skip_terms] = true
  end

  ##
  # return permitted user parameters
  def user_params
    params.require(:user).permit(:email, :email_confirmation, :display_name,
                                 :auth_provider, :auth_uid,
                                 :pass_crypt, :pass_crypt_confirmation)
  end

  ##
  # check signup acls
  def check_signup_allowed(email = nil)
    domain = if email.nil?
               nil
             else
               email.split("@").last
             end

    mx_servers = if domain.nil?
                   nil
                 else
                   domain_mx_servers(domain)
                 end

    if blocked = Acl.no_account_creation(request.remote_ip, :domain => domain, :mx => mx_servers)
      logger.info "Blocked signup from #{request.remote_ip} for #{email}"

      render :action => "blocked"
    end

    !blocked
  end

  ##
  # get list of MX servers for a domains
  def domain_mx_servers(domain)
    Resolv::DNS.open do |dns|
      dns.getresources(domain, Resolv::DNS::Resource::IN::MX).collect(&:exchange).collect(&:to_s)
    end
  end

  ##
  # check if this user has a gravatar and set the user pref is true
  def gravatar_enable(user)
    # code from example https://en.gravatar.com/site/implement/images/ruby/
    return false if user.avatar.attached?

    hash = Digest::MD5.hexdigest(user.email.downcase)
    url = "https://www.gravatar.com/avatar/#{hash}?d=404" # without d=404 we will always get an image back
    response = OSM.http_client.get(URI.parse(url))
    oldsetting = user.image_use_gravatar
    user.image_use_gravatar = response.success?
    oldsetting != user.image_use_gravatar
  end

  ##
  # display a message about th current status of the gravatar setting
  def gravatar_status_message(user)
    if user.image_use_gravatar
      t "users.account.gravatar.enabled"
    else
      t "users.account.gravatar.disabled"
    end
  end
end
