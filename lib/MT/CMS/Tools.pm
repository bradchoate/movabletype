# Movable Type (r) Open Source (C) 2001-2011 Six Apart, Ltd.
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id$
package MT::CMS::Tools;

use strict;
use Symbol;

use MT::I18N qw( wrap_text );
use MT::Util
    qw( encode_url encode_html decode_html encode_js trim dir_separator );

sub system_check {
    my $app = shift;

    if ( my $blog_id = $app->param('blog_id') ) {
        return $app->return_to_dashboard( redirect => 1 );
    }
    if ( !$app->can_do('open_system_check_screen') ) {
        return $app->permission_denied();
    }

    my %param;

    my $author_class = $app->model('author');
    $param{user_count}
        = $author_class->count( { type => MT::Author::AUTHOR() } );

    $param{commenter_count} = 0;
    $param{screen_id}       = "system-check";

    require MT::Memcached;
    if ( MT::Memcached->is_available ) {
        $param{memcached_enabled} = 1;
        my $inst = MT::Memcached->instance;
        my $key  = 'syscheck-' . $$;
        $inst->add( $key, $$ );
        if ( $inst->get($key) == $$ ) {
            $inst->delete($key);
            $param{memcached_active} = 1;
        }
    }

    $param{server_modperl} = 1 if $ENV{MOD_PERL};
    $param{server_fastcgi} = 1 if $ENV{FAST_CGI};

    $param{syscheck_html} = get_syscheck_content($app) || '';

    $app->load_tmpl( 'system_check.tmpl', \%param );
}

sub get_syscheck_content {
    my $app     = shift;
    my $sess_id = $app->session->id;
    my $syscheck_url
        = $app->base
        . $app->mt_path
        . $app->config('CheckScript')
        . '?view=tools&version='
        . MT->version_id
        . '&session_id='
        . $sess_id
        . '&language='
        . MT->current_language;

    my $ua = $app->new_ua( { timeout => 20 } );
    return unless $ua;
    $ua->max_size(undef) if $ua->can('max_size');

    my $req = new HTTP::Request( GET => $syscheck_url );
    my $resp = $ua->request($req);
    return unless $resp->is_success();
    my $result = $resp->content();
    if ($result) {
        require MT::Sanitize;

        # allowed html
        my $spec
            = '* style class id,ul,li,div,span,br,h2,h3,strong,code,blockquote,p,textarea';
        $result = Encode::decode_utf8($result) if !Encode::is_utf8($result);
        $result = MT::Sanitize->sanitize( $result, $spec );
    }
    return $result;
}

sub start_recover {
    my $app     = shift;
    my ($param) = @_;
    my $cfg     = $app->config;
    $param ||= {};
    $param->{'email'} = $app->param('email');
    $param->{'return_to'} 
        = $app->param('return_to')
        || $cfg->ReturnToURL
        || '';
    if ( $param->{recovered} ) {
        $param->{return_to} = MT::Util::encode_js( $param->{return_to} );
    }
    $param->{'can_signin'} = ( ref $app eq 'MT::App::CMS' ) ? 1 : 0;

    $app->add_breadcrumb( $app->translate('Password Recovery') );

    my $blog_id = $app->param('blog_id');
    $param->{'blog_id'} = $blog_id;
    my $tmpl = $app->load_global_tmpl(
        { identifier => 'new_password_reset_form', }, $blog_id );
    if ( !$tmpl ) {
        $tmpl = $app->load_tmpl('cms/dialog/recover.tmpl');
    }
    $param->{system_template} = 1;
    $tmpl->param($param);
    return $tmpl;
}

sub recover_password {
    my $app      = shift;
    my $email    = $app->param('email') || '';
    my $username = $app->param('name');

    $email = trim($email);
    $username = trim($username) if $username;

    if ( !$email ) {
        return $app->start_recover(
            {   error => $app->translate(
                    'Email Address is required for password reset.'),
            }
        );
    }

    # Searching user by email (and username)
    my $class
        = ref $app eq 'MT::App::Upgrader'
        ? 'MT::BasicAuthor'
        : $app->model('author');
    eval "use $class;";

    my @all_authors = $class->load(
        { email => $email, ( $username ? ( name => $username ) : () ) } );
    my @authors;
    my $user;
    foreach (@all_authors) {
        next unless $_->password && ( $_->password ne '(none)' );
        push( @authors, $_ );
    }
    if ( !@authors ) {
        return $app->start_recover(
            {   error => $app->translate('User not found'),
                ( $username ? ( not_unique_email => 1 ) : () ),
            }
        );
    }
    elsif ( @authors > 1 ) {
        return $app->start_recover( { not_unique_email => 1, } );
    }
    $user = pop @authors;

    # Generate Token
    require MT::Util::Captcha;
    my $salt    = MT::Util::Captcha->_generate_code(8);
    my $expires = time + ( 60 * 60 );
    my $token   = MT::Util::perl_sha1_digest_hex(
        $salt . $expires . $app->config->SecretToken );

    $user->password_reset($salt);
    $user->password_reset_expires($expires);
    $user->password_reset_return_to( $app->param('return_to') )
        if $app->param('return_to');
    $user->save;

    # Send mail to user
    my %head = (
        id      => 'recover_password',
        To      => $email,
        From    => $app->config('EmailAddressMain') || $email,
        Subject => $app->translate("Password Recovery")
    );
    my $charset = $app->charset;
    my $mail_enc = uc( $app->config('MailEncoding') || $charset );
    $head{'Content-Type'} = qq(text/plain; charset="$mail_enc");

    my $blog_id = $app->param('blog_id');
    my $body    = $app->build_email(
        'recover-password',
        {         link_to_login => $app->base
                . $app->uri
                . "?__mode=new_pw&token=$token&email="
                . encode_url($email)
                . ( $blog_id ? "&blog_id=$blog_id" : '' ),
        }
    );

    require MT::Mail;
    MT::Mail->send( \%head, $body )
        or return $app->error(
        $app->translate(
            "Error sending mail ([_1]); please fix the problem, then "
                . "try again to recover your password.",
            MT::Mail->errstr
        )
        );

    return $app->start_recover( { recovered => 1, } );
}

sub new_password {
    my $app = shift;
    my ($param) = @_;
    $param ||= {};

    my $token = $app->param('token');
    if ( !$token ) {
        return $app->start_recover(
            { error => $app->translate('Password reset token not found'), } );
    }

    my $email = $app->param('email');
    if ( !$email ) {
        return $app->start_recover(
            { error => $app->translate('Email address not found'), } );
    }

    my $class = $app->model('author');
    my @users = $class->load( { email => $email } );
    if ( !@users ) {
        return $app->start_recover(
            { error => $app->translate('User not found'), } );
    }

    # comparing token
    require MT::Util::Captcha;
    my $user;
    for my $u (@users) {
        my $salt    = $u->password_reset;
        my $expires = $u->password_reset_expires;
        my $compare = MT::Util::perl_sha1_digest_hex(
            $salt . $expires . $app->config->SecretToken );
        if ( $compare eq $token ) {
            if ( time > $u->password_reset_expires ) {
                return $app->start_recover(
                    {   error => $app->translate(
                            'Your request to change your password has expired.'
                        ),
                    }
                );
            }
            $user = $u;
            last;
        }
    }

    if ( !$user ) {
        return $app->start_recover(
            { error => $app->translate('Invalid password reset request'), } );
    }

    # Password reset
    my $new_password = $app->param('password');
    if ($new_password) {
        my $again = $app->param('password_again');
        if ( !$again ) {
            $param->{'error'}
                = $app->translate('Please confirm your new password');
        }
        elsif ( $new_password ne $again ) {
            $param->{'error'} = $app->translate('Passwords do not match');
        }
        else {
            my $redirect = $user->password_reset_return_to || '';

            $user->set_password($new_password);
            $user->password_reset(undef);
            $user->password_reset_expires(undef);
            $user->password_reset_return_to(undef);
            $user->save;
            $app->param( 'username', $user->name )
                if $user->type == MT::Author::AUTHOR();

            if ( ref $app eq 'MT::App::CMS' && !$redirect ) {
                $app->login;
                return $app->return_to_dashboard( redirect => 1 );
            }
            else {
                if ( !$redirect ) {
                    my $cfg = $app->config;
                    $redirect = $cfg->ReturnToURL || '';
                }
                $app->make_commenter_session($user);
                if ($redirect) {
                    return $app->redirect( MT::Util::encode_html($redirect) );
                }
                else {
                    return $app->redirect_to_edit_profile();
                }
            }
        }
    }

    $param->{'email'}          = $email;
    $param->{'token'}          = $token;
    $param->{'password'}       = $app->param('password');
    $param->{'password_again'} = $app->param('password_again');
    $app->add_breadcrumb( $app->translate('Password Recovery') );

    my $blog_id = $app->param('blog_id');
    $param->{'blog_id'} = $blog_id if $blog_id;
    my $tmpl = $app->load_global_tmpl( { identifier => 'new_password', },
        $blog_id );
    if ( !$tmpl ) {
        $tmpl = $app->load_tmpl('cms/dialog/new_password.tmpl');
    }
    $param->{system_template} = 1;
    $tmpl->param($param);
    return $tmpl;
}

sub do_list_action {
    my $app = shift;

    #$app->validate_magic or return;
    # plugin_action_selector should always (?) be in the query; use it?
    my $action_name = $app->param('action_name');
    my $type        = $app->param('_type');
    my ($the_action)
        = ( grep { $_->{key} eq $action_name }
            @{ $app->list_actions($type) } );
    return $app->errtrans(
        "That action ([_1]) is apparently not implemented!", $action_name )
        unless $the_action;

    unless ( ref( $the_action->{code} ) ) {
        if ( my $plugin = $the_action->{plugin} ) {
            $the_action->{code}
                = $app->handler_to_coderef( $the_action->{handler}
                    || $the_action->{code} );
        }
    }

    if ( $app->param('all_selected') ) {
        $app->setup_filtered_ids;
    }
    else {
        my @ids = $app->param('id');
        if ( scalar @ids == 1 && $ids[0] =~ /,/ ) {
            $app->param( 'id', split ',', $ids[0] );
        }
    }
    if ( $app->param('xhr') ) {
        my $res = $the_action->{code}->($app);
        if ( !defined $res && !$app->errstr ) {
            return $app->json_error(
                MT->translate(
                    q{Error occured while act [_1]: [_2]},
                    $the_action->label,
                    $app->errstr
                )
            );
        }
        elsif ( !defined $res ) {
            return;
        }
        return $app->forward( 'filtered_list',
            ( 'HASH' eq ref $res ? %$res : () ) );
    }
    $the_action->{code}->($app);
}

sub do_page_action {
    my $app = shift;

    # plugin_action_selector should always (?) be in the query; use it?
    my $action_name = $app->param('action_name');
    my $type        = $app->param('_type');
    my ($the_action)
        = ( grep { $_->{key} eq $action_name }
            @{ $app->page_actions($type) } );
    return $app->errtrans(
        "That action ([_1]) is apparently not implemented!", $action_name )
        unless $the_action;

    unless ( ref( $the_action->{code} ) ) {
        if ( my $plugin = $the_action->{plugin} ) {
            $the_action->{code}
                = $app->handler_to_coderef( $the_action->{handler}
                    || $the_action->{code} );
        }
    }
    $the_action->{code}->($app);
}

sub cfg_system_general {
    my $app = shift;
    my %param;
    if ( $app->param('blog_id') ) {
        return $app->return_to_dashboard( redirect => 1 );
    }

    return $app->permission_denied()
        unless $app->user->is_superuser();
    my $cfg = $app->config;
    $app->add_breadcrumb( $app->translate('General Settings') );
    $param{nav_config}   = 1;
    $param{nav_settings} = 1;
    $param{languages}    = MT::I18N::languages_list( $app,
        $app->config('DefaultUserLanguage') );
    my $tag_delim = $app->config('DefaultUserTagDelimiter') || 'comma';
    $param{"tag_delim_$tag_delim"} = 1;

    ( my $tz = $app->config('DefaultTimezone') ) =~ s![-\.]!_!g;
    $tz =~ s!_00$!!;
    $param{ 'server_offset_' . $tz } = 1;

    $param{personal_weblog_readonly}
        = $app->config->is_readonly('NewUserAutoProvisioning');
    $param{personal_weblog} = $app->config->NewUserAutoProvisioning ? 1 : 0;
    if ( my $id = $param{new_user_template_blog_id}
        = $app->config('NewUserTemplateBlogId') || '' )
    {
        my $blog = MT::Blog->load($id);
        if ($blog) {
            $param{new_user_template_blog_name} = $blog->name;
        }
        else {
            $app->config( 'NewUserTemplateBlogId', undef, 1 );
            $cfg->save_config();
            delete $param{new_user_template_blog_id};
        }
    }

    if ( $app->param('to_email_address') ) {
        return $app->errtrans(
            "You don't have a system email address configured.  Please set this first, save it, then try the test email again."
        ) unless ( $cfg->EmailAddressMain );
        return $app->errtrans("Please enter a valid email address")
            unless (
            MT::Util::is_valid_email( $app->param('to_email_address') ) );

        my %head = (
            To      => $app->param('to_email_address'),
            From    => $cfg->EmailAddressMain,
            Subject => $app->translate("Test email from Movable Type")
        );

        my $body
            = $app->translate("This is the test email sent by Movable Type.");

        require MT::Mail;
        MT::Mail->send( \%head, $body )
            or return $app->error(
            $app->translate("Mail was not properly sent") );

        $app->log(
            {   message => $app->translate(
                    'Test e-mail was successfully sent to [_1]',
                    $app->param('to_email_address')
                ),
                level    => MT::Log::INFO(),
                class    => 'system',
                category => 'email',
            }
        );
        $param{test_mail_sent} = 1;
    }

    my @config_warnings;
    for my $config_directive (
        qw( EmailAddressMain DebugMode PerformanceLogging
        PerformanceLoggingPath PerformanceLoggingThreshold )
        )
    {
        push( @config_warnings, $config_directive )
            if $app->config->is_readonly($config_directive);
    }
    my $config_warning = join( ", ", @config_warnings ) if (@config_warnings);

    $param{config_warning} = $app->translate(
        "These setting(s) are overridden by a value in the MT configuration file: [_1]. Remove the value from the configuration file in order to control the value on this page.",
        $config_warning
    ) if $config_warning;
    $param{system_email_address}            = $cfg->EmailAddressMain;
    $param{system_debug_mode}               = $cfg->DebugMode;
    $param{system_performance_logging}      = $cfg->PerformanceLogging;
    $param{system_performance_logging_path} = $cfg->PerformanceLoggingPath;
    $param{system_performance_logging_threshold}
        = $cfg->PerformanceLoggingThreshold;
    $param{track_revisions} = $cfg->TrackRevisions;
    $param{saved}           = $app->param('saved');
    $param{error}           = $app->param('error');
    $param{screen_class}    = "settings-screen system-general-settings";

    # for feedback settings
    $param{comment_disable}      = $cfg->AllowComments            ? 0 : 1;
    $param{ping_disable}         = $cfg->AllowPings               ? 0 : 1;
    $param{disabled_notify_ping} = $cfg->DisableNotificationPings ? 1 : 0;
    $param{system_no_email} = 1 unless $cfg->EmailAddressMain;
    my $send = $cfg->OutboundTrackbackLimit || 'any';

    if ( $send =~ m/^(any|off|selected|local)$/ ) {
        $param{ "trackback_send_" . $cfg->OutboundTrackbackLimit } = 1;
        if ( $send eq 'selected' ) {
            my @domains = $cfg->OutboundTrackbackDomains;
            my $domains = join "\n", @domains;
            $param{trackback_send_domains} = $domains;
        }
    }
    else {
        $param{"trackback_send_any"} = 1;
    }
    $param{saved}        = $app->param('saved');
    $param{screen_class} = "settings-screen system-feedback-settings";
    $app->load_tmpl( 'cfg_system_general.tmpl', \%param );
}

sub save_cfg_system_general {
    my $app = shift;
    $app->validate_magic or return;
    return $app->permission_denied()
        unless $app->user->is_superuser();
    $app->validate_magic or return;
    my $cfg = $app->config;
    $app->config( 'TrackRevisions', $app->param('track_revisions') ? 1 : 0,
        1 );

    # construct the message to the activity log
    my @meta_messages = ();
    push(
        @meta_messages,
        $app->translate(
            'Email address is [_1]',
            $app->param('system_email_address')
        )
    ) if ( $app->param('system_email_address') =~ /\w+/ );
    push(
        @meta_messages,
        $app->translate(
            'Debug mode is [_1]',
            $app->param('system_debug_mode')
        )
    ) if ( $app->param('system_debug_mode') =~ /\d+/ );
    if ( $app->param('system_performance_logging') ) {
        push( @meta_messages, $app->translate('Performance logging is on') );
    }
    else {
        push( @meta_messages, $app->translate('Performance logging is off') );
    }
    push(
        @meta_messages,
        $app->translate(
            'Performance log path is [_1]',
            $app->param('system_performance_logging_path')
        )
    ) if ( $app->param('system_performance_logging_path') =~ /\w+/ );
    push(
        @meta_messages,
        $app->translate(
            'Performance log threshold is [_1]',
            $app->param('system_performance_logging_threshold')
        )
    ) if ( $app->param('system_performance_logging_threshold') =~ /\d+/ );

    # actually assign the changes
    $app->config( 'EmailAddressMain',
        $app->param('system_email_address') || undef, 1 );
    $app->config( 'DebugMode', $app->param('system_debug_mode'), 1 )
        if ( $app->param('system_debug_mode') =~ /\d+/ );
    if ( $app->param('system_performance_logging') ) {
        $app->config( 'PerformanceLogging', 1, 1 );
    }
    else {
        $app->config( 'PerformanceLogging', 0, 1 );
    }
    $app->config( 'PerformanceLoggingPath',
        $app->param('system_performance_logging_path'), 1 )
        if ( $app->param('system_performance_logging_path') =~ /\w+/ );
    $app->config( 'PerformanceLoggingThreshold',
        $app->param('system_performance_logging_threshold'), 1 )
        if ( $app->param('system_performance_logging_threshold') =~ /\d+/ );

    # construct the message to the activity log

    if ( $app->param('comment_disable') ) {
        push( @meta_messages, 'Allow comments is on' );
    }
    else {
        push( @meta_messages, 'Allow comments is off' );
    }
    if ( $app->param('ping_disable') ) {
        push( @meta_messages, 'Allow trackbacks is on' );
    }
    else {
        push( @meta_messages, 'Allow trackbacks is off' );
    }
    if ( $app->param('disable_notify_ping') ) {
        push( @meta_messages, 'Allow outbound trackbacks is on' );
    }
    else {
        push( @meta_messages, 'Allow outbound trackbacks is off' );
    }
    push( @meta_messages,
        'Outbound trackback limit is ' . $app->param('trackback_send') )
        if ( $app->param('trackback_send') =~ /\w+/ );

    # throw the messages in the activity log
    if ( scalar(@meta_messages) > 0 ) {
        my $message = join( ', ', @meta_messages );
        $app->log(
            {   message =>
                    $app->translate('System Settings Changes Took Place'),
                level    => MT::Log::INFO(),
                class    => 'system',
                metadata => $message,
                category => 'edit',
            }
        );
    }

    # for feedback settings
    $cfg->AllowComments( ( $app->param('comment_disable') ? 0 : 1 ), 1 );
    $cfg->AllowPings( ( $app->param('ping_disable') ? 0 : 1 ), 1 );
    $cfg->DisableNotificationPings(
        ( $app->param('disable_notify_ping') ? 1 : 0 ), 1 );
    my $send = $app->param('trackback_send') || 'any';
    if ( $send =~ m/^(any|off|selected|local)$/ ) {
        $cfg->OutboundTrackbackLimit( $send, 1 );
        if ( $send eq 'selected' ) {
            my $domains = $app->param('trackback_send_domains') || '';
            $domains =~ s/[\r\n]+/ /gs;
            $domains =~ s/\s{2,}/ /gs;
            my @domains = split /\s/, $domains;
            $cfg->OutboundTrackbackDomains( \@domains, 1 );
        }
    }
    $cfg->save_config();
    require MT::Touch;
    MT::Touch->touch( 0, 'config' );
    $app->redirect(
        $app->uri(
            'mode' => 'cfg_system_general',
            args   => { saved => 1 }
        ),
        UseMeta => $ENV{FAST_CGI},
    );
}

sub upgrade {
    my $app = shift;

    if ( $ENV{FAST_CGI} ) {

        # don't enter the FCGI loop.
        require MT::Bootstrap;
        MT::Bootstrap::fcgi_sig_handler('Upgrade');
    }

    # check for an empty database... no author table would do it...
    my $driver         = MT::Object->driver;
    my $upgrade_script = $app->config('UpgradeScript');
    my $user_class     = MT->model('author');
    if ( !$driver || !$driver->table_exists($user_class) ) {
        return $app->redirect( $app->path
                . $upgrade_script
                . $app->uri_params( mode => 'install' ) );
    }
    return $app->redirect( $app->path . $upgrade_script );
}

sub recover_profile_password {
    my $app = shift;
    $app->validate_magic or return;
    return $app->permission_denied()
        unless $app->user->is_superuser();

    my $q = $app->param;

    require MT::Auth;
    require MT::Log;
    if ( !MT::Auth->can_recover_password ) {
        $app->log(
            {   message => $app->translate(
                    "Invalid password recovery attempt; can't recover password in this configuration"
                ),
                level    => MT::Log::SECURITY(),
                class    => 'system',
                category => 'recover_profile_password',
            }
        );
        return $app->error("Can't recover password in this configuration");
    }

    my $author_id = $q->param('author_id');
    my $author    = MT::Author->load($author_id);

    return $app->error( $app->translate("Invalid author_id") )
        if !$author || $author->type != MT::Author::AUTHOR() || !$author_id;

    my ( $rc, $res )
        = reset_password( $app, $author, $author->hint, $author->name );

    if ($rc) {
        my $url = $app->uri(
            'mode' => 'view',
            args   => { _type => 'author', recovered => 1, id => $author_id }
        );
        $app->redirect($url);
    }
    else {
        $app->error($res);
    }
}

sub start_backup {
    my $app     = shift;
    my $user    = $app->user;
    my $blog_id = $app->param('blog_id');
    my $perms   = $app->permissions;

    return $app->permission_denied()
        unless $app->can_do('start_backup');

    my %param = ();
    if ( defined($blog_id) ) {
        $param{blog_id} = $blog_id;
        $app->add_breadcrumb( $app->translate('Backup') );
        my $blog = $app->model('blog')->load($blog_id);
        if ( defined $blog && !$blog->is_blog ) {
            my $blogs = $blog->blogs;
            my @blog_ids = map { $_->id } @$blogs;
            push @blog_ids, $blog_id;
            $param{backup_what} = join ',', @blog_ids;
        }
        else {
            $param{backup_what} = $blog_id;
        }
    }
    else {
        $app->add_breadcrumb( $app->translate('Backup & Restore') );
    }
    $param{system_overview_nav} = 1 unless $blog_id;
    $param{nav_backup} = 1;
    require MT::Util::Archive;
    my @formats = MT::Util::Archive->available_formats();
    $param{archive_formats} = \@formats;

    my $limit = $app->config('CGIMaxUpload') || 2048;
    $param{over_300}  = 1 if $limit >= 300 * 1024;
    $param{over_500}  = 1 if $limit >= 500 * 1024;
    $param{over_1024} = 1 if $limit >= 1024 * 1024;
    $param{over_2048} = 1 if $limit >= 2048 * 1024;

    my $tmp = $app->config('TempDir');
    unless ( ( -d $tmp ) && ( -w $tmp ) ) {
        $param{error}
            = $app->translate(
            'Temporary directory needs to be writable for backup to work correctly.  Please check TempDir configuration directive.'
            );
    }
    $app->load_tmpl( 'backup.tmpl', \%param );
}

sub start_restore {
    my $app     = shift;
    my $user    = $app->user;
    my $blog_id = $app->param('blog_id');
    my $perms   = $app->permissions;

    return $app->permission_denied()
        unless $app->can_do('start_restore');

    return $app->return_to_dashboard( redirect => 1 )
        if $blog_id;

    my %param = ();
    if ( defined($blog_id) ) {
        $param{blog_id} = $blog_id;
        $app->add_breadcrumb( $app->translate('Backup') );
        my $blog = $app->model('blog')->load($blog_id);
    }
    else {
        $app->add_breadcrumb( $app->translate('Backup & Restore') );
    }
    $param{system_overview_nav} = 1 unless $blog_id;
    $param{nav_backup} = 1;

    eval "require XML::SAX";
    $param{missing_sax} = 1 if $@;

    my $tmp = $app->config('TempDir');
    unless ( ( -d $tmp ) && ( -w $tmp ) ) {
        $param{error}
            = $app->translate(
            'Temporary directory needs to be writable for restore to work correctly.  Please check TempDir configuration directive.'
            );
    }

    my $website_class = $app->model('website');
    unless ( my $count = $website_class->count() ) {
        $param{error} = $app->translate(
            'No website could be found. You must create a website first.');
    }

    $app->load_tmpl( 'restore.tmpl', \%param );
}

sub backup {
    my $app     = shift;
    my $user    = $app->user;
    my $q       = $app->param;
    my $blog_id = $q->param('blog_id');
    my $perms   = $app->permissions;
    unless ( $user->is_superuser ) {
        return $app->permission_denied()
            unless defined($blog_id) && $perms->can_do('backup_blog');
    }
    $app->validate_magic() or return;

    my $blog_ids = $q->param('backup_what');

    my $size = $q->param('size_limit') || 0;
    return $app->errtrans( '[_1] is not a number.', encode_html($size) )
        if $size !~ /^\d+$/;

    my @blog_ids = split ',', $blog_ids;
    if (@blog_ids) {
        my @child_ids;
        my $blog_class = $app->model('blog');
        foreach my $bid (@blog_ids) {
            my $target = $blog_class->load($bid);
            if ( !$target->is_blog && scalar @{ $target->blogs } ) {
                my @blogs = map { $_->id } @{ $target->blogs };
                push @child_ids, @blogs;
            }
        }
        push @blog_ids, @child_ids if @child_ids;
    }

    my $archive = $q->param('backup_archive_format');
    my $enc     = $app->charset || 'utf-8';
    my @ts      = gmtime(time);
    my $ts      = sprintf "%04d-%02d-%02d-%02d-%02d-%02d", $ts[5] + 1900,
        $ts[4] + 1,
        @ts[ 3, 2, 1, 0 ];
    my $file = "Movable_Type-$ts" . '-Backup';

    my $param = { return_args => '__mode=start_backup' };
    $app->{no_print_body} = 1;
    $app->add_breadcrumb(
        $app->translate('Backup & Restore'),
        $app->uri( mode => 'start_backup' )
    );
    $app->add_breadcrumb( $app->translate('Backup') );
    $param->{system_overview_nav} = 1 if defined($blog_ids) && $blog_ids;
    $param->{blog_id}  = $blog_id  if $blog_id;
    $param->{blog_ids} = $blog_ids if $blog_ids;
    $param->{nav_backup} = 1;

    local $| = 1;
    $app->send_http_header('text/html');
    $app->print_encode(
        $app->build_page( 'include/backup_start.tmpl', $param ) );
    require File::Temp;
    require File::Spec;
    use File::Copy;
    my $temp_dir = $app->config('TempDir');

    require MT::BackupRestore;
    my $count_term
        = @blog_ids ? { class => '*', blog_id => [ [0], @blog_ids ] }
        : $blog_id ? { class => '*', blog_id => [ 0, $blog_id ] }
        :            { class => '*' };
    my $num_assets = $app->model('asset')->count($count_term);
    my $printer;
    my $splitter;
    my $finisher;
    my $progress = sub { _progress( $app, @_ ); };
    my $fh;
    my $fname;
    my $arc_buf;

    if ( !( $size || $num_assets ) ) {
        $splitter = sub { };

        if ( '0' eq $archive ) {
            ( $fh, my $filepath )
                = File::Temp::tempfile( 'xml.XXXXXXXX', DIR => $temp_dir );
            ( my $vol, my $dir, $fname ) = File::Spec->splitpath($filepath);
            $printer = sub {
                my ($data) = @_;
                print $fh $data;
                return length($data);
            };
            $finisher = sub {
                my ($asset_files) = @_;
                close $fh;
                _backup_finisher( $app, $fname, $param );
            };
        }
        else {    # archive/compress files
            $printer = sub {
                my ($data) = @_;
                $arc_buf .= $data;
                return length($data);
            };
            $finisher = sub {
                require MT::Util::Archive;
                my ($asset_files) = @_;
                ( my $fh, my $filepath )
                    = File::Temp::tempfile( $archive . '.XXXXXXXX',
                    DIR => $temp_dir );
                ( my $vol, my $dir, $fname )
                    = File::Spec->splitpath($filepath);
                close $fh;
                unlink $filepath;
                my $arc = MT::Util::Archive->new( $archive, $filepath );
                $arc->add_string( Encode::encode_utf8($arc_buf),
                    "$file.xml" );
                $arc->add_string(
                    "<manifest xmlns='"
                        . MT::BackupRestore::NS_MOVABLETYPE()
                        . "'><file type='backup' name='$file.xml' /></manifest>",
                    "$file.manifest"
                );
                $arc->close;
                _backup_finisher( $app, $fname, $param );
            };
        }
    }
    else {
        my @files;
        my $filename = File::Spec->catfile( $temp_dir, $file . "-1.xml" );
        $fh = gensym();
        open $fh, ">$filename";
        my $url
            = $app->uri
            . "?__mode=backup_download&name=$file-1.xml&magic_token="
            . $app->current_magic;
        $url .= "&blog_id=$blog_id" if defined($blog_id);
        push @files,
            {
            url      => $url,
            filename => $file . "-1.xml"
            };
        $printer = sub {
            require bytes;
            my ($data) = @_;
            print $fh $data;
            return bytes::length($data);
        };
        $splitter = sub {
            my ( $findex, $header ) = @_;

            print $fh '</movabletype>';
            close $fh;
            my $filename
                = File::Spec->catfile( $temp_dir, $file . "-$findex.xml" );
            $fh = gensym();
            open $fh, ">$filename";
            my $url
                = $app->uri
                . "?__mode=backup_download&name=$file-$findex.xml&magic_token="
                . $app->current_magic;
            $url .= "&blog_id=$blog_id" if defined($blog_id);
            push @files,
                {
                url      => $url,
                filename => $file . "-$findex.xml"
                };
            print $fh $header;
        };
        $finisher = sub {
            my ($asset_files) = @_;
            close $fh;
            my $filename = File::Spec->catfile( $temp_dir, "$file.manifest" );
            $fh = gensym();
            open $fh, ">$filename";
            print $fh "<manifest xmlns='"
                . MT::BackupRestore::NS_MOVABLETYPE() . "'>\n";
            for my $file (@files) {
                my $name = $file->{filename};
                print $fh "<file type='backup' name='$name' />\n";
            }
            require MT::FileMgr::Local;
            for my $id ( keys %$asset_files ) {
                my $name = $id . '-' . $asset_files->{$id}->[2];
                my $tmp = File::Spec->catfile( $temp_dir, $name );
                unless (
                    copy(
                        MT::FileMgr::Local::_local(
                            $asset_files->{$id}->[1]
                        ),
                        MT::FileMgr::Local::_local($tmp)
                    )
                    )
                {
                    $app->log(
                        {   message => $app->translate(
                                'Copying file [_1] to [_2] failed: [_3]',
                                $asset_files->{$id}->[1],
                                $tmp, $!
                            ),
                            level    => MT::Log::WARNING(),
                            class    => 'system',
                            category => 'backup'
                        }
                    );
                    next;
                }
                my $xml_name = $asset_files->{$id}->[2];
                $xml_name =~ s/'/&apos;/g;
                print $fh "<file type='asset' name='"
                    . $xml_name
                    . "' asset_id='"
                    . $id
                    . "' />\n";
                my $url
                    = $app->uri
                    . "?__mode=backup_download&assetname="
                    . MT::Util::encode_url($name)
                    . "&magic_token="
                    . $app->current_magic;
                $url .= "&blog_id=$blog_id" if defined($blog_id);
                push @files,
                    {
                    url      => $url,
                    filename => MT::FileMgr::Local::_local($name),
                    };
            }
            print $fh "</manifest>\n";
            close $fh;
            my $url
                = $app->uri
                . "?__mode=backup_download&name=$file.manifest&magic_token="
                . $app->current_magic;
            $url .= "&blog_id=$blog_id" if defined($blog_id);
            push @files,
                {
                url      => $url,
                filename => "$file.manifest"
                };
            if ( '0' eq $archive ) {
                for my $f (@files) {
                    $f->{filename}
                        = MT::FileMgr::Local::_syserr( $f->{filename} )
                        if ( $f->{filename}
                        && !Encode::is_utf8( $f->{filename} ) );
                }
                $param->{files_loop} = \@files;
                $param->{tempdir}    = $temp_dir;
                my @fnames = map { $_->{filename} } @files;
                _backup_finisher( $app, \@fnames, $param );
            }
            else {
                my ( $fh_arc, $filepath )
                    = File::Temp::tempfile( $archive . '.XXXXXXXX',
                    DIR => $temp_dir );
                ( my $vol, my $dir, $fname )
                    = File::Spec->splitpath($filepath);
                require MT::Util::Archive;
                close $fh_arc;
                unlink $filepath;
                my $arc = MT::Util::Archive->new( $archive, $filepath );
                for my $f (@files) {
                    $arc->add_file( $temp_dir, $f->{filename} );
                }
                $arc->close;

                # for safery, don't unlink before closing $arc here.
                for my $f (@files) {
                    unlink File::Spec->catfile( $temp_dir, $f->{filename} );
                }
                _backup_finisher( $app, $fname, $param );
            }
        };
    }

    my @tsnow    = gmtime(time);
    my $metadata = {
        backup_by => MT::Util::encode_xml( $app->user->name, 1 ) . '(ID: '
            . $app->user->id . ')',
        backup_on => sprintf(
            "%04d-%02d-%02dT%02d:%02d:%02d",
            $tsnow[5] + 1900,
            $tsnow[4] + 1,
            @tsnow[ 3, 2, 1, 0 ]
        ),
        backup_what    => join( ',', @blog_ids ),
        schema_version => $app->config('SchemaVersion'),
    };
    MT::BackupRestore->backup( \@blog_ids, $printer, $splitter, $finisher,
        $progress, $size * 1024,
        $enc, $metadata );
}

sub backup_download {
    my $app     = shift;
    my $user    = $app->user;
    my $blog_id = $app->param('blog_id');
    unless ( $user->is_superuser ) {
        my $perms = $app->permissions;
        return $app->permission_denied()
            unless defined($blog_id) && $perms->can_do('backup_download');
    }
    $app->validate_magic() or return;
    my $filename  = $app->param('filename');
    my $assetname = $app->param('assetname');
    my $temp_dir  = $app->config('TempDir');
    my $newfilename;

    $app->{hide_goback_button} = 1;

    if ( defined($assetname) ) {
        my $sess = MT::Session->load( { kind => 'BU', name => $assetname } );
        if ( !defined($sess) || !$sess ) {
            return $app->errtrans("Specified file was not found.");
        }
        $newfilename = $filename = $assetname;
        $sess->remove;
    }
    elsif ( defined($filename) ) {
        my $sess = MT::Session->load( { kind => 'BU', name => $filename } );
        if ( !defined($sess) || !$sess ) {
            return $app->errtrans("Specified file was not found.");
        }
        my @ts = gmtime( $sess->start );
        my $ts = sprintf "%04d-%02d-%02d-%02d-%02d-%02d", $ts[5] + 1900,
            $ts[4] + 1, @ts[ 3, 2, 1, 0 ];
        $newfilename = "Movable_Type-$ts" . '-Backup';
        $sess->remove;
    }
    else {
        $newfilename = $app->param('name');
        return
            if $newfilename
                !~ /Movable_Type-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-Backup(?:-\d+)?\.\w+/;
        $filename = $newfilename;
    }

    require File::Spec;
    my $fname = File::Spec->catfile( $temp_dir, $filename );

    my $contenttype;
    if ( !defined($assetname) && ( $filename =~ m/^xml\..+$/i ) ) {
        my $enc = $app->charset || 'utf-8';
        $contenttype = "text/xml; charset=$enc";
        $newfilename .= '.xml';
    }
    elsif ( $filename =~ m/^tgz\..+$/i ) {
        $contenttype = 'application/x-tar-gz';
        $newfilename .= '.tar.gz';
    }
    elsif ( $filename =~ m/^zip\..+$/i ) {
        $contenttype = 'application/zip';
        $newfilename .= '.zip';
    }
    else {
        $contenttype = 'application/octet-stream';
        if ( $app->param->user_agent =~ /MSIE/ ) {
            $newfilename = Encode::encode( 'Shift_JIS', $newfilename );
        }
    }

    if ( open( my $fh, "<", MT::FileMgr::Local::_local($fname) ) ) {
        binmode $fh;
        $app->{no_print_body} = 1;
        $app->set_header( "Content-Disposition" => 'attachment; filename="'
                . $newfilename
                . '"' );
        $app->send_http_header($contenttype);
        my $data;
        while ( read $fh, my ($chunk), 8192 ) {
            $data .= $chunk;
        }
        close $fh;
        $app->print($data);
        $app->log(
            {   message => $app->translate(
                    '[_1] successfully downloaded backup file ([_2])',
                    $app->user->name, $fname
                ),
                level    => MT::Log::INFO(),
                class    => 'system',
                category => 'restore'
            }
        );
        MT::FileMgr::Local->delete($fname);
    }
    else {
        $app->errtrans('Specified file was not found.');
    }
}

sub restore {
    my $app  = shift;
    my $user = $app->user;
    return $app->permission_denied()
        unless $app->can_do('restore_blog');
    $app->validate_magic() or return;

    my $q = $app->param;

    my ($fh) = $app->upload_info('file');
    my $uploaded = $q->param('file');
    my ( $volume, $directories, $uploaded_filename )
        = File::Spec->splitpath($uploaded)
        if defined($uploaded);
    $app->mode('start_restore');
    if ( defined($uploaded_filename)
        && ( $uploaded_filename =~ /^.+\.manifest$/i ) )
    {
        return restore_upload_manifest( $app, $fh );
    }

    my $param = { return_args => '__mode=dashboard' };

    $app->add_breadcrumb(
        $app->translate('Backup & Restore'),
        $app->uri( mode => 'start_restore' )
    );
    $app->add_breadcrumb( $app->translate('Restore') );
    $param->{system_overview_nav} = 1;
    $param->{nav_backup}          = 1;

    $app->{no_print_body} = 1;

    local $| = 1;
    $app->send_http_header('text/html');

    $app->print_encode( $app->build_page( 'restore_start.tmpl', $param ) );

    require File::Path;

    my $error = '';
    my $result;
    if ( !$fh ) {
        $param->{restore_upload} = 0;
        my $dir = $app->config('ImportPath');
        my ( $blog_ids, $asset_ids )
            = restore_directory( $app, $dir, \$error );
        if ( defined $blog_ids ) {
            $param->{open_dialog} = 1;
            $param->{blog_ids}    = join( ',', @$blog_ids );
            $param->{asset_ids}   = join( ',', @$asset_ids )
                if defined $asset_ids;
            $param->{tmp_dir} = $dir;
        }
        elsif ( defined $asset_ids ) {
            my %asset_ids = @$asset_ids;
            my %error_assets;
            _restore_non_blog_asset( $app, $dir, $asset_ids, \%error_assets );
            if (%error_assets) {
                my $data;
                while ( my ( $key, $value ) = each %error_assets ) {
                    $data .= $app->translate( 'MT::Asset#[_1]: ', $key )
                        . $value . "\n";
                }
                my $message
                    = $app->translate(
                    'Some of the actual files for assets could not be restored.'
                    );
                $app->log(
                    {   message  => $message,
                        level    => MT::Log::WARNING(),
                        class    => 'system',
                        category => 'restore',
                        metadata => $data,
                    }
                );
                $error .= $message;
            }
        }
    }
    else {
        $param->{restore_upload} = 1;
        if ( $uploaded_filename =~ /^.+\.xml$/i ) {
            my $blog_ids = restore_file( $app, $fh, \$error );
            if ( defined $blog_ids ) {
                $param->{open_dialog} = 1;
                $param->{blog_ids} = join( ',', @$blog_ids );
            }
        }
        else {
            require MT::Util::Archive;
            my $arc;
            if ( $uploaded_filename =~ /^.+\.tar(\.gz)?$/i ) {
                $arc = MT::Util::Archive->new( 'tgz', $fh );
            }
            elsif ( $uploaded_filename =~ /^.+\.zip$/i ) {
                $arc = MT::Util::Archive->new( 'zip', $fh );
            }
            else {
                $error
                    = $app->translate(
                    'Please use xml, tar.gz, zip, or manifest as a file extension.'
                    );
            }
            unless ($arc) {
                $result = 0;
                $param->{restore_success} = 0;
                if ($error) {
                    $param->{error} = $error;
                }
                else {
                    $error = MT->translate('Unknown file format');
                    $app->log(
                        {   message  => $error . ":$uploaded_filename",
                            level    => MT::Log::WARNING(),
                            class    => 'system',
                            category => 'restore',
                            metadata => MT::Util::Archive->errstr,
                        }
                    );
                }
                $app->print_encode($error);
                $app->print_encode(
                    $app->build_page( "restore_end.tmpl", $param ) );
                close $fh if $fh;
                return 1;
            }
            my $temp_dir = $app->config('TempDir');
            require File::Temp;
            my $tmp = File::Temp::tempdir( $uploaded_filename . 'XXXX',
                DIR => $temp_dir );
            $tmp = Encode::decode( MT->config->PublishCharset, $tmp );
            $arc->extract($tmp);
            $arc->close;
            my ( $blog_ids, $asset_ids )
                = restore_directory( $app, $tmp, \$error );

            if ( defined $blog_ids ) {
                $param->{open_dialog} = 1;
                $param->{blog_ids} = join( ',', @$blog_ids )
                    if defined $blog_ids;
                $param->{asset_ids} = join( ',', @$asset_ids )
                    if defined $asset_ids;
                $param->{tmp_dir} = $tmp;
            }
            elsif ( defined $asset_ids ) {
                my %asset_ids = @$asset_ids;
                my %error_assets;
                _restore_non_blog_asset( $app, $tmp, \%asset_ids,
                    \%error_assets );
                if (%error_assets) {
                    my $data;
                    while ( my ( $key, $value ) = each %error_assets ) {
                        $data .= $app->translate( 'MT::Asset#[_1]: ', $key )
                            . $value . "\n";
                    }
                    my $message
                        = $app->translate(
                        'Some of the actual files for assets could not be restored.'
                        );
                    $app->log(
                        {   message  => $message,
                            level    => MT::Log::WARNING(),
                            class    => 'system',
                            category => 'restore',
                            metadata => $data,
                        }
                    );
                    $error .= $message;
                }
            }
        }
    }
    $param->{restore_success} = !$error;
    $param->{error} = $error if $error;
    if ( ( exists $param->{open_dialog} ) && ( $param->{open_dialog} ) ) {
        $param->{dialog_mode} = 'dialog_adjust_sitepath';
        $param->{dialog_params}
            = 'magic_token='
            . $app->current_magic
            . '&amp;blog_ids='
            . $param->{blog_ids}
            . '&amp;asset_ids='
            . $param->{asset_ids}
            . '&amp;tmp_dir='
            . encode_url( $param->{tmp_dir} );
        if ( ( $param->{restore_upload} ) && ( $param->{restore_upload} ) ) {
            $param->{dialog_params} .= '&amp;restore_upload=1';
        }
        if ( ( $param->{error} ) && ( $param->{error} ) ) {
            $param->{dialog_params}
                .= '&amp;error=' . encode_url( $param->{error} );
        }
    }

    $app->print_encode( $app->build_page( "restore_end.tmpl", $param ) );
    close $fh if $fh;
    1;
}

sub restore_premature_cancel {
    my $app  = shift;
    my $user = $app->user;
    return $app->permission_denied()
        if !$user->is_superuser;
    $app->validate_magic() or return;

    require JSON;
    my $deferred = JSON::from_json( $app->param('deferred_json') )
        if $app->param('deferred_json');
    my $param = { restore_success => 1 };
    if ( defined $deferred && ( scalar( keys %$deferred ) ) ) {
        _log_dirty_restore( $app, $deferred );
        my $log_url
            = $app->uri( mode => 'list', args => { '_type' => 'log' } );
        $param->{restore_success} = 0;
        my $message
            = $app->translate(
            'Some objects were not restored because their parent objects were not restored.'
            );
        $param->{error} 
            = $message . '  '
            . $app->translate(
            "Detailed information is in the <a href='javascript:void(0)' onclick='closeDialog(\"[_1]\")'>activity log</a>.",
            $log_url
            );
    }
    else {
        $app->log(
            {   message => $app->translate(
                    '[_1] has canceled the multiple files restore operation prematurely.',
                    $app->user->name
                ),
                level    => MT::Log::WARNING(),
                class    => 'system',
                category => 'restore',
            }
        );
    }
    $app->redirect(
        $app->uri( mode => 'list', args => { '_type' => 'log' } ) );
}

sub _restore_non_blog_asset {
    my ( $app, $tmp_dir, $asset_ids, $error_assets ) = @_;
    require MT::FileMgr;
    my $fmgr = MT::FileMgr->new('Local');
    foreach my $new_id ( keys %$asset_ids ) {
        my $asset = $app->model('asset')->load($new_id);
        next unless $asset;
        my $old_id   = $asset_ids->{$new_id};
        my $filename = $old_id . '-' . $asset->file_name;
        my $file     = File::Spec->catfile( $tmp_dir, $filename );
        MT::BackupRestore->restore_asset( $file, $asset, $old_id, $fmgr,
            $error_assets, sub { $app->print_encode(@_); } );
    }
}

sub adjust_sitepath {
    my $app  = shift;
    my $user = $app->user;
    return $app->permission_denied()
        if !$user->is_superuser;
    $app->validate_magic() or return;

    require MT::BackupRestore;

    my $q         = $app->param;
    my $tmp_dir   = $q->param('tmp_dir');
    my $error     = $q->param('error') || q();
    my %asset_ids = split ',', $q->param('asset_ids');

    $app->{no_print_body} = 1;

    local $| = 1;
    $app->send_http_header('text/html');

    $app->print_encode( $app->build_page( 'dialog/restore_start.tmpl', {} ) );

    my $asset_class = $app->model('asset');
    my %error_assets;
    my %blogs_meta;
    my @p = $q->param;
    foreach my $p (@p) {
        next unless $p =~ /^site_path_(\d+)/;
        my $id   = $1;
        my $blog = $app->model('blog')->load($id)
            or return $app->error(
            $app->translate( 'Can\'t load blog #[_1].', $id ) );
        my $old_site_path      = scalar $q->param("old_site_path_$id");
        my $old_site_url       = scalar $q->param("old_site_url_$id");
        my $site_path          = scalar $q->param("site_path_$id") || q();
        my $site_url           = scalar $q->param("site_url_$id") || q();
        my $site_url_path      = scalar $q->param("site_url_path_$id") || q();
        my $site_url_subdomain = scalar $q->param("site_url_subdomain_$id")
            || q();
        $site_url_subdomain .= '.'
            if $site_url_subdomain && $site_url_subdomain !~ /\.$/;
        my $parent_id = scalar $q->param("parent_id_$id") || undef;
        my $site_path_absolute = scalar $q->param("site_path_absolute_$id")
            || q();
        my $use_absolute = scalar $q->param("use_absolute_$id") || q();

        if ($use_absolute) {
            $site_path = scalar $q->param("site_path_absolute_$id") || q();
        }
        $blog->site_path($site_path);

        $blog->parent_id($parent_id)
            if $blog->is_blog() && $parent_id;
        if ($site_url_path) {
            $blog->site_url("$site_url_subdomain/::/$site_url_path");
        }
        else {
            $blog->site_url($site_url);
        }

        if ( $site_url || $site_url_path || $site_path ) {
            $app->print_encode(
                $app->translate(
                    "Changing Site Path for the blog '[_1]' (ID:[_2])...",
                    encode_html( $blog->name ), $blog->id
                )
            );
        }
        else {
            $app->print_encode(
                $app->translate(
                    "Removing Site Path for the blog '[_1]' (ID:[_2])...",
                    encode_html( $blog->name ), $blog->id
                )
            );
        }
        my $old_archive_path = scalar $q->param("old_archive_path_$id");
        my $old_archive_url  = scalar $q->param("old_archive_url_$id");
        my $archive_path     = scalar $q->param("archive_path_$id") || q();
        my $archive_url      = scalar $q->param("archive_url_$id") || q();
        my $archive_url_path = scalar $q->param("archive_url_path_$id")
            || q();
        my $archive_url_subdomain
            = scalar $q->param("archive_url_subdomain_$id") || q();
        $archive_url_subdomain .= '.'
            if $archive_url_subdomain && $archive_url_subdomain !~ /\.$/;
        my $archive_path_absolute
            = scalar $q->param("archive_path_absolute_$id") || q();
        my $use_absolute_archive
            = scalar $q->param("use_absolute_archive_$id") || q();

        if ($use_absolute_archive) {
            $archive_path = $archive_path_absolute;
        }
        $blog->archive_path($archive_path);

        if ($archive_url_path) {
            $blog->archive_url("$archive_url_subdomain/::/$archive_url_path");
        }
        else {
            $blog->archive_url($archive_url);
        }
        if (   ( $old_archive_url && ( $archive_url || $archive_url_path ) )
            || ( $old_archive_path && $archive_path ) )
        {
            $app->print_encode(
                "\n"
                    . $app->translate(
                    "Changing Archive Path for the blog '[_1]' (ID:[_2])...",
                    encode_html( $blog->name ),
                    $blog->id
                    )
            );
        }
        elsif ( $old_archive_url || $old_archive_path ) {
            $app->print_encode(
                "\n"
                    . $app->translate(
                    "Removing Archive Path for the blog '[_1]' (ID:[_2])...",
                    encode_html( $blog->name ),
                    $blog->id
                    )
            );
        }
        $blog->save
            or $app->print_encode( $app->translate("failed") . "\n" ), next;
        $app->print_encode( $app->translate("ok") . "\n" );

        $blogs_meta{$id} = {
            'old_archive_path' => $old_archive_path,
            'old_archive_url'  => $old_archive_url,
            'archive_path'     => $blog->archive_path,
            'archive_url'      => $blog->archive_url,
            'old_site_path'    => $old_site_path,
            'old_site_url'     => $old_site_url,
            'site_path'        => $blog->site_path,
            'site_url'         => $blog->site_url,
        };
        next unless %asset_ids;

        my $fmgr = ( $site_path || $archive_path ) ? $blog->file_mgr : undef;
        next unless defined $fmgr;

        my @assets = $asset_class->load( { blog_id => $id, class => '*' } );
        foreach my $asset (@assets) {
            my $path = $asset->column('file_path');
            my $url  = $asset->column('url');
            if ($archive_path) {
                $path =~ s/^\Q$old_archive_path\E/$archive_path/i;
                $asset->file_path($path);
            }
            if ($archive_url) {
                $url =~ s/^\Q$old_archive_url\E/$archive_url/i;
                $asset->url($url);
            }
            if ($site_path) {
                $path =~ s/^\Q$old_site_path\E/$site_path/i;
                $asset->file_path($path);
            }
            if ($site_url) {
                $url =~ s/^\Q$old_site_url\E/$site_url/i;
                $asset->url($url);
            }
            $app->print_encode(
                $app->translate(
                    "Changing file path for the asset '[_1]' (ID:[_2])...",
                    encode_html( $asset->label ), $asset->id
                )
            );
            $asset->save
                or $app->print_encode( $app->translate("failed") . "\n" ),
                next;
            $app->print_encode( $app->translate("ok") . "\n" );
            unless ( $q->param('redirect') ) {
                my $old_id   = delete $asset_ids{ $asset->id };
                my $filename = "$old_id-" . $asset->file_name;
                my $file     = File::Spec->catfile( $tmp_dir, $filename );
                MT::BackupRestore->restore_asset( $file, $asset, $old_id,
                    $fmgr, \%error_assets, sub { $app->print_encode(@_); } );
            }
        }
    }
    unless ( $q->param('redirect') ) {
        _restore_non_blog_asset( $app, $tmp_dir, \%asset_ids,
            \%error_assets );
    }
    if (%error_assets) {
        my $data;
        while ( my ( $key, $value ) = each %error_assets ) {
            $data .= $app->translate( 'MT::Asset#[_1]: ', $key ) 
                . $value . "\n";
        }
        my $message = $app->translate(
            'Some of the actual files for assets could not be restored.');
        $app->log(
            {   message  => $message,
                level    => MT::Log::WARNING(),
                class    => 'system',
                category => 'restore',
                metadata => $data,
            }
        );
        $error .= $message;
    }

    if ($tmp_dir) {
        require File::Path;
        File::Path::rmtree($tmp_dir);
    }

    my $param = {};
    if ( scalar $q->param('redirect') && $q->param('current_file') ) {
        $param->{restore_end}
            = 0;    # redirect=1 means we are from multi-uploads
        $param->{blogs_meta} = MT::Util::to_json( \%blogs_meta );
        $param->{next_mode}  = 'dialog_restore_upload';
    }
    else {
        $param->{restore_end} = 1;
    }
    if ($error) {
        $param->{error}     = $error;
        $param->{error_url} = $app->base
            . $app->uri( mode => 'list', args => { '_type' => 'log' } );
    }
    for my $key (
        qw(files last redirect is_dirty is_asset objects_json deferred_json))
    {
        $param->{$key} = scalar $q->param($key);
    }
    $param->{name}   = $q->param('current_file');
    $param->{assets} = encode_html( $q->param('assets') );
    $app->print_encode(
        $app->build_page( 'dialog/restore_end.tmpl', $param ) );
}

sub dialog_restore_upload {
    my $app  = shift;
    my $user = $app->user;
    return $app->permission_denied()
        if !$user->is_superuser;
    $app->validate_magic() or return;

    my $q = $app->param;

    my $current        = $q->param('current_file');
    my $last           = $q->param('last');
    my $files          = $q->param('files');
    my $assets_json    = $q->param('assets');
    my $is_asset       = $q->param('is_asset') || 0;
    my $schema_version = $q->param('schema_version')
        || $app->config('SchemaVersion');
    my $overwrite_template = $q->param('overwrite_templates') ? 1 : 0;

    my $objects  = {};
    my $deferred = {};
    require JSON;
    my $objects_json = $q->param('objects_json') if $q->param('objects_json');
    $deferred = JSON::from_json( $q->param('deferred_json') )
        if $q->param('deferred_json');

    my ($fh) = $app->upload_info('file');

    my $param = {};
    $param->{start}         = $q->param('start') || 0;
    $param->{is_asset}      = $is_asset;
    $param->{name}          = $current;
    $param->{files}         = $files;
    $param->{assets}        = $assets_json;
    $param->{last}          = $last;
    $param->{redirect}      = 1;
    $param->{is_dirty}      = $q->param('is_dirty');
    $param->{objects_json}  = $objects_json if defined($objects_json);
    $param->{deferred_json} = MT::Util::to_json($deferred)
        if defined($deferred);
    $param->{blogs_meta}          = $q->param('blogs_meta');
    $param->{schema_version}      = $schema_version;
    $param->{overwrite_templates} = $overwrite_template;

    my $uploaded = $q->param('file') || $q->param('fname');
    if ( defined($uploaded) ) {
        $uploaded =~ s!\\!/!g;    ## Change backslashes to forward slashes
        $uploaded =~ s!^.*/!!;    ## Get rid of full directory paths
        if ( $uploaded =~ m!\.\.|\0|\|! ) {
            $param->{error}
                = $app->translate( "Invalid filename '[_1]'", $uploaded );
            return $app->load_tmpl( 'dialog/restore_upload.tmpl', $param );
        }
        $uploaded
            = Encode::is_utf8($uploaded)
            ? $uploaded
            : Encode::decode( $app->charset, $uploaded );
    }
    if ( defined($uploaded) ) {
        if ( $current ne $uploaded ) {
            close $fh if $uploaded;
            $param->{error}
                = $app->translate( 'Please upload [_1] in this page.',
                $current );
            return $app->load_tmpl( 'dialog/restore_upload.tmpl', $param );
        }
    }

    if ( !$fh ) {
        $param->{error} = $app->translate('File was not uploaded.')
            if !( $q->param('redirect') );
        return $app->load_tmpl( 'dialog/restore_upload.tmpl', $param );
    }

    $app->{no_print_body} = 1;

    local $| = 1;
    $app->send_http_header('text/html');

    $app->print_encode(
        $app->build_page( 'dialog/restore_start.tmpl', $param ) );

    if ( defined $objects_json ) {
        my $objects_tmp = JSON::from_json($objects_json);
        my %class2ids;

        # { MT::CLASS#OLD_ID => NEW_ID }
        for my $key ( keys %$objects_tmp ) {
            my ( $class, $old_id ) = split '#', $key;
            if ( exists $class2ids{$class} ) {
                my $newids = $class2ids{$class}->{newids};
                push @$newids, $objects_tmp->{$key};
                my $keymaps = $class2ids{$class}->{keymaps};
                push @$keymaps,
                    { newid => $objects_tmp->{$key}, oldid => $old_id };
            }
            else {
                $class2ids{$class} = {
                    newids  => [ $objects_tmp->{$key} ],
                    keymaps => [
                        { newid => $objects_tmp->{$key}, oldid => $old_id }
                    ]
                };
            }
        }
        for my $class ( keys %class2ids ) {
            eval "require $class;";
            next if $@;
            my $newids  = $class2ids{$class}->{newids};
            my $keymaps = $class2ids{$class}->{keymaps};
            my @objs    = $class->load( { id => $newids } );
            for my $obj (@objs) {
                my @old_ids = grep { $_->{newid} eq $obj->id } @$keymaps;
                my $old_id = $old_ids[0]->{oldid};
                $objects->{"$class#$old_id"} = $obj;
            }
        }
    }

    my $assets = JSON::from_json( decode_html($assets_json) )
        if ( defined($assets_json) && $assets_json );
    $assets = [] if !defined($assets);
    my $asset;
    my @errors;
    my $error_assets = {};
    require MT::BackupRestore;
    my $blog_ids;
    my $asset_ids;

    if ($is_asset) {
        $asset = shift @$assets;
        $asset->{fh} = $fh;
        my $blogs_meta = JSON::from_json( $q->param('blogs_meta') || '{}' );
        MT::BackupRestore->_restore_asset_multi( $asset, $objects,
            $error_assets, sub { $app->print_encode(@_); }, $blogs_meta );
        if ( defined( $error_assets->{ $asset->{asset_id} } ) ) {
            $app->log(
                {   message => $app->translate('Restoring a file failed: ')
                        . $error_assets->{ $asset->{asset_id} },
                    level    => MT::Log::WARNING(),
                    class    => 'system',
                    category => 'restore',
                }
            );
        }
    }
    else {
        ( $blog_ids, $asset_ids ) = eval {
            MT::BackupRestore->restore_process_single_file( $fh, $objects,
                $deferred, \@errors, $schema_version, $overwrite_template,
                sub { _progress( $app, @_ ) } );
        };
        if ($@) {
            $last = 1;
        }
    }

    my @files = split( ',', $files );
    my $file_next = shift @files if scalar(@files);
    if ( !defined($file_next) ) {
        if ( scalar(@$assets) ) {
            $asset             = $assets->[0];
            $file_next         = $asset->{asset_id} . '-' . $asset->{name};
            $param->{is_asset} = 1;
        }
    }
    $param->{files}  = join( ',', @files );
    $param->{assets} = encode_html( MT::Util::to_json($assets) );
    $param->{name}   = $file_next;
    if ( 0 < scalar(@files) ) {
        $param->{last} = 0;
    }
    elsif ( 0 >= scalar(@$assets) - 1 ) {
        $param->{last} = 1;
    }
    else {
        $param->{last} = 0;
    }
    $param->{is_dirty} = scalar( keys %$deferred );

    if ( $last && defined($blog_ids) && scalar(@$blog_ids) ) {
        $param->{error}     = join( '; ', @errors );
        $param->{next_mode} = 'dialog_adjust_sitepath';
        $param->{blog_ids}  = join( ',', @$blog_ids );
        $param->{asset_ids} = join( ',', @$asset_ids )
            if defined($asset_ids);
    }
    elsif ($last) {
        $param->{restore_end} = 1;
        if ( $param->{is_dirty} ) {
            _log_dirty_restore( $app, $deferred );
            my $log_url = $app->base
                . $app->uri( mode => 'list', args => { '_type' => 'log' } );
            $param->{error}
                = $app->translate(
                'Some objects were not restored because their parent objects were not restored.'
                );
            $param->{error_url} = $log_url;
        }
        elsif ( scalar( keys %$error_assets ) ) {
            $param->{error} = $app->translate(
                'Some of the files were not restored correctly.');
            my $log_url
                = $app->uri( mode => 'list', args => { '_type' => 'log' } );
            $param->{error_url} = $log_url;
        }
        elsif ( scalar @errors ) {
            $param->{error} = join '; ', @errors;
            my $log_url
                = $app->uri( mode => 'list', args => { '_type' => 'log' } );
            $param->{error_url} = $log_url;
        }
        else {
            $app->log(
                {   message => $app->translate(
                        "Successfully restored objects to Movable Type system by user '[_1]'",
                        $app->user->name
                    ),
                    level    => MT::Log::INFO(),
                    class    => 'system',
                    category => 'restore'
                }
            );
            $param->{ok_url}
                = $app->uri( mode => 'start_restore', args => {} );
        }
    }
    else {
        my %objects_json;
        %objects_json = map { $_ => $objects->{$_}->id } keys %$objects;
        $param->{objects_json}  = MT::Util::to_json( \%objects_json );
        $param->{deferred_json} = MT::Util::to_json($deferred);

        $param->{error} = join( '; ', @errors );
        if ( defined($blog_ids) && scalar(@$blog_ids) ) {
            $param->{next_mode} = 'dialog_adjust_sitepath';
            $param->{blog_ids}  = join( ',', @$blog_ids );
            $param->{asset_ids} = join( ',', @$asset_ids )
                if defined($asset_ids);
        }
        else {
            $param->{next_mode} = 'dialog_restore_upload';
        }
    }
    MT->run_callbacks( 'restore', $objects, $deferred, \@errors,
        sub { _progress( $app, @_ ) } );

    $app->print_encode(
        $app->build_page( 'dialog/restore_end.tmpl', $param ) );
    close $fh if $fh;
}

sub dialog_adjust_sitepath {
    my $app  = shift;
    my $user = $app->user;
    return $app->permission_denied()
        if !$user->is_superuser;
    $app->validate_magic() or return;

    my $q          = $app->param;
    my $tmp_dir    = $q->param('tmp_dir');
    my $error      = $q->param('error') || q();
    my $uploaded   = $q->param('restore_upload') || 0;
    my @blog_ids   = split ',', $q->param('blog_ids');
    my $asset_ids  = $q->param('asset_ids');
    my $blog_class = $app->model('blog');
    my @blogs      = $blog_class->load( { id => \@blog_ids } );
    my ( @blogs_loop, @website_loop );
    my $param = {};

    foreach my $blog (@blogs) {
        if ( $blog->is_blog() ) {
            my $params = {
                name          => $blog->name,
                id            => $blog->id,
                old_site_path => $blog->column('site_path'),
                $blog->column('archive_path')
                ? ( old_archive_path => $blog->column('archive_path') )
                : (),
                $blog->column('parent_id') ? ( parent_id => $blog->parent_id )
                : (),
            };
            $params->{site_path_absolute} = 1
                if $blog_class->is_site_path_absolute(
                $blog->column('site_path') );
            $params->{archive_path_absolute} = 1
                if exists( $params->{old_archive_path} )
                    && $blog_class->is_site_path_absolute(
                        $blog->column('archive_path')
                    );
            $params->{old_site_url} = $blog->site_url;
            my @raw_site_url = $blog->raw_site_url;
            if ( 2 == @raw_site_url ) {
                my $subdomain = $raw_site_url[0];
                $subdomain =~ s/\.$//;
                $params->{old_site_url_subdomain} = $subdomain;
                $params->{old_site_url_path}      = $raw_site_url[1];
            }
            $params->{old_archive_url} = $blog->archive_url
                if $blog->column('archive_url');
            my @raw_archive_url = $blog->raw_archive_url;
            if ( 2 == @raw_archive_url ) {
                my $subdomain = $raw_archive_url[0];
                $subdomain =~ s/\.$//;
                $params->{old_archive_url_subdomain} = $subdomain;
                $params->{old_archive_url_path}      = $raw_archive_url[1];
            }
            $param->{enabled_archives} = 1
                if $params->{old_archive_url}
                    || $params->{old_archive_url_subdomain}
                    || $params->{old_archive_url_path}
                    || $params->{old_archive_path};
            push @blogs_loop, $params;
        }
        else {
            push @website_loop,
                {
                name          => $blog->name,
                id            => $blog->id,
                old_site_path => $blog->column('site_path'),
                old_site_url  => $blog->column('site_url'),
                };
        }
    }

    # Load all website
    my $iter = MT->model('website')->load_iter();
    my @all_websites;
    while ( my $website = $iter->() ) {
        push @all_websites,
            {
            website_name      => $website->name,
            website_id        => $website->id,
            website_site_path => $website->site_path,
            website_site_url  => $website->site_url,
            };
    }

    $param = { blogs_loop => \@blogs_loop, tmp_dir => $tmp_dir, %$param };
    $param->{error}          = $error         if $error;
    $param->{restore_upload} = $uploaded      if $uploaded;
    $param->{asset_ids}      = $asset_ids     if $asset_ids;
    $param->{website_loop}   = \@website_loop if @website_loop;
    $param->{all_websites}   = \@all_websites if @all_websites;
    $param->{path_separator} = MT::Util->dir_separator;
    for my $key (
        qw(files assets last redirect is_dirty is_asset objects_json deferred_json)
        )
    {
        $param->{$key} = $q->param($key) if $q->param($key);
    }
    $param->{name}      = $q->param('current_file');
    $param->{screen_id} = "adjust-sitepath";
    $app->load_tmpl( 'dialog/adjust_sitepath.tmpl', $param );
}

sub convert_to_html {
    my $app       = shift;
    my $format    = $app->param('format') || '';
    my @formats   = split /\s*,\s*/, $format;
    my $text      = $app->param('text') || '';
    my $text_more = $app->param('text_more') || '';
    my $result    = {
        text      => $app->apply_text_filters( $text,      \@formats ),
        text_more => $app->apply_text_filters( $text_more, \@formats ),
        format    => $formats[0],
    };
    return $app->json_result($result);
}

sub update_list_prefs {
    my $app   = shift;
    my $prefs = $app->list_pref( $app->param('_type') );
    $app->call_return;
}

sub recover_passwords {
    my $app = shift;
    my @id  = $app->param('id');

    return $app->permission_denied()
        unless $app->user->is_superuser();

    my $class
        = ref $app eq 'MT::App::Upgrader'
        ? 'MT::BasicAuthor'
        : $app->model('author');
    eval "use $class;";

    my @msg_loop;
    foreach (@id) {
        my $author = $class->load($_)
            or next;
        my ( $rc, $res ) = reset_password( $app, $author, $author->hint );
        push @msg_loop, { message => $res };
    }

    $app->load_tmpl( 'recover_password_result.tmpl',
        { message_loop => \@msg_loop, return_url => $app->return_uri } );
}

sub reset_password {
    my $app      = shift;
    my ($author) = $_[0];
    my $hint     = $_[1];
    my $name     = $_[2];

    require MT::Auth;
    require MT::Log;
    if ( !MT::Auth->can_recover_password ) {
        $app->log(
            {   message => $app->translate(
                    "Invalid password recovery attempt; can't recover password in this configuration"
                ),
                level    => MT::Log::SECURITY(),
                class    => 'system',
                category => 'recover_password',
            }
        );
        return ( 0,
            $app->translate("Can't recover password in this configuration") );
    }

    $app->log(
        {   message => $app->translate(
                "Invalid user name '[_1]' in password recovery attempt", $name
            ),
            level    => MT::Log::SECURITY(),
            class    => 'system',
            category => 'recover_password',
        }
        ),
        return ( 0,
        $app->translate("User name or password hint is incorrect.") )
        unless $author;
    return (
        0,
        $app->translate(
            "User has not set pasword hint; cannot recover password")
    ) if ( $hint && !$author->hint );

    $app->log(
        {   message => $app->translate(
                "Invalid attempt to recover password (used hint '[_1]')",
                $hint
            ),
            level    => MT::Log::SECURITY(),
            class    => 'system',
            category => 'recover_password'
        }
        ),
        return ( 0,
        $app->translate("User name or password hint is incorrect.") )
        unless $author->hint eq $hint;

    return (
        0,
        $app->translate(
            "User '[_1]' (user #[_2]) does not have email address",
            $author->name, $author->id
        )
    ) unless $author->email;

    # Generate Token
    require MT::Util::Captcha;
    my $salt    = MT::Util::Captcha->_generate_code(8);
    my $expires = time + ( 60 * 60 );
    my $token   = MT::Util::perl_sha1_digest_hex(
        $salt . $expires . $app->config->SecretToken );

    $author->password_reset($salt);
    $author->password_reset_expires($expires);
    $author->password_reset_return_to(undef);
    $author->save;

    my $message
        = $app->translate(
        "A password reset link has been sent to [_3] for user  '[_1]' (user #[_2]).",
        $author->name, $author->id, $author->email );
    $app->log(
        {   message  => $message,
            level    => MT::Log::SECURITY(),
            class    => 'system',
            category => 'recover_password'
        }
    );

    # Send mail to user
    my $email = $author->email;
    my %head  = (
        id      => 'recover_password',
        To      => $email,
        From    => $app->config('EmailAddressMain') || $email,
        Subject => $app->translate("Password Recovery")
    );
    my $charset = $app->charset;
    my $mail_enc = uc( $app->config('MailEncoding') || $charset );
    $head{'Content-Type'} = qq(text/plain; charset="$mail_enc");

    my $body = $app->build_email(
        'recover-password',
        {         link_to_login => $app->base
                . $app->uri
                . "?__mode=new_pw&token=$token&email="
                . encode_url($email),
        }
    );

    require MT::Mail;
    MT::Mail->send( \%head, $body )
        or return $app->error(
        $app->translate(
            "Error sending mail ([_1]); please fix the problem, then "
                . "try again to recover your password.",
            MT::Mail->errstr
        )
        );

    ( 1, $message );
}

sub restore_file {
    my $app = shift;
    my ( $fh, $errormsg ) = @_;
    my $q              = $app->param;
    my $schema_version = $app->config->SchemaVersion;

    #my $schema_version =
    #  $q->param('ignore_schema_conflict')
    #  ? 'ignore'
    #  : $app->config('SchemaVersion');
    my $overwrite_template = $q->param('overwrite_global_templates') ? 1 : 0;

    require MT::BackupRestore;
    my ( $deferred, $blogs )
        = MT::BackupRestore->restore_file( $fh, $errormsg, $schema_version,
        $overwrite_template, sub { _progress( $app, @_ ); } );

    if ( !defined($deferred) || scalar( keys %$deferred ) ) {
        _log_dirty_restore( $app, $deferred );
        my $log_url
            = $app->uri( mode => 'list', args => { '_type' => 'log' } );
        $$errormsg .= '; ' if $$errormsg;
        $$errormsg .= $app->translate(
            'Some objects were not restored because their parent objects were not restored.  Detailed information is in the <a href="javascript:void(0);" onclick="closeDialog(\'[_1]\');">activity log</a>.',
            $log_url
        );
        return $blogs;
    }
    if ($$errormsg) {
        $app->log(
            {   message  => $$errormsg,
                level    => MT::Log::ERROR(),
                class    => 'system',
                category => 'restore',
            }
        );
        return $blogs;
    }

    $app->log(
        {   message => $app->translate(
                "Successfully restored objects to Movable Type system by user '[_1]'",
                $app->user->name
            ),
            level    => MT::Log::INFO(),
            class    => 'system',
            category => 'restore'
        }
    );

    $blogs;
}

sub restore_directory {
    my $app = shift;
    my ( $dir, $error ) = @_;

    if ( !-d $dir ) {
        $$error = $app->translate( '[_1] is not a directory.', $dir );
        return ( undef, undef );
    }

    my $q              = $app->param;
    my $schema_version = $app->config->SchemaVersion;

    #my $schema_version =
    #  $q->param('ignore_schema_conflict')
    #  ? 'ignore'
    #  : $app->config('SchemaVersion');

    my $overwrite_template = $q->param('overwrite_global_templates') ? 1 : 0;

    my @errors;
    my %error_assets;
    require MT::BackupRestore;
    my ( $deferred, $blogs, $assets )
        = MT::BackupRestore->restore_directory( $dir, \@errors,
        \%error_assets, $schema_version, $overwrite_template,
        sub { _progress( $app, @_ ); } );

    if ( scalar @errors ) {
        $$error = $app->translate('Error occured during restore process.');
        $app->log(
            {   message  => $$error,
                level    => MT::Log::WARNING(),
                class    => 'system',
                category => 'restore',
                metadata => join( '; ', @errors ),
            }
        );
    }
    return ( $blogs, $assets ) unless ( defined($deferred) && %$deferred );

    if ( scalar( keys %error_assets ) ) {
        my $data;
        while ( my ( $key, $value ) = each %error_assets ) {
            $data .= $app->translate( 'MT::Asset#[_1]: ', $key ) 
                . $value . "\n";
        }
        my $message = $app->translate('Some of files could not be restored.');
        $app->log(
            {   message  => $message,
                level    => MT::Log::WARNING(),
                class    => 'system',
                category => 'restore',
                metadata => $data,
            }
        );
        $$error .= $message;
    }

    if ( scalar( keys %$deferred ) ) {
        _log_dirty_restore( $app, $deferred );
        my $log_url
            = $app->uri( mode => 'list', args => { '_type' => 'log' } );
        $$error = $app->translate(
            'Some objects were not restored because their parent objects were not restored.  Detailed information is in the <a href="javascript:void(0);" onclick="closeDialog(\'[_1]\');">activity log</a>.',
            $log_url
        );
        return ( $blogs, $assets );
    }

    return ( $blogs, $assets ) if $$error;

    $app->log(
        {   message => $app->translate(
                "Successfully restored objects to Movable Type system by user '[_1]'",
                $app->user->name
            ),
            level    => MT::Log::INFO(),
            class    => 'system',
            category => 'restore'
        }
    );
    return ( $blogs, $assets );
}

sub restore_upload_manifest {
    my $app  = shift;
    my ($fh) = @_;
    my $user = $app->user;
    return $app->permission_denied()
        if !$user->is_superuser;
    $app->validate_magic() or return;

    my $q = $app->param;

    require MT::BackupRestore;
    my $backups = MT::BackupRestore->process_manifest($fh);
    return $app->errtrans(
        "Uploaded file was not a valid Movable Type backup manifest file.")
        if !defined($backups);

    my $files     = $backups->{files};
    my $assets    = $backups->{assets};
    my $file_next = shift @$files if defined($files) && scalar(@$files);
    my $assets_json;
    my $param = {};

    if ( !defined($file_next) ) {
        if ( scalar(@$assets) > 0 ) {
            my $asset = shift @$assets;
            $file_next = $asset->{name};
            $param->{is_asset} = 1;
        }
    }
    $assets_json = encode_url( MT::Util::to_json($assets) )
        if scalar(@$assets) > 0;
    $param->{files}    = join( ',', @$files );
    $param->{assets}   = $assets_json;
    $param->{filename} = $file_next;
    $param->{last}     = scalar(@$files) ? 0 : ( scalar(@$assets) ? 0 : 1 );
    $param->{open_dialog}    = 1;
    $param->{schema_version} = $app->config->SchemaVersion;

    #$param->{schema_version} =
    #  $q->param('ignore_schema_conflict')
    #  ? 'ignore'
    #  : $app->config('SchemaVersion');
    $param->{overwrite_templates}
        = $q->param('overwrite_global_templates') ? 1 : 0;

    $param->{dialog_mode} = 'dialog_restore_upload';
    $param->{dialog_params}
        = 'start=1'
        . '&amp;magic_token='
        . $app->current_magic
        . '&amp;files='
        . $param->{files}
        . '&amp;assets='
        . $param->{assets}
        . '&amp;current_file='
        . $param->{filename}
        . '&amp;last='
        . $param->{'last'}
        . '&amp;schema_version='
        . $param->{schema_version}
        . '&amp;overwrite_templates='
        . $param->{overwrite_templates}
        . '&amp;redirect=1';
    if ( length $param->{dialog_params} > 2083 )
    {    # 2083 is Maximum URL length in IE
        $param->{error} = $app->translate(
            "Manifest file '[_1]' is too large. Please use import direcotry for restore.",
            $param->{filename}
        );
        $param->{open_dialog} = 0;
        $app->mode('start_restore');
    }
    $app->load_tmpl( 'restore.tmpl', $param );

    #close $fh if $fh;
}

sub _backup_finisher {
    my $app = shift;
    my ( $fnames, $param ) = @_;
    unless ( ref $fnames ) {
        $fnames = [$fnames];
    }
    $param->{filename}       = $fnames->[0];
    $param->{backup_success} = 1;
    require MT::Session;
    MT::Session->remove( { kind => 'BU' } );
    foreach my $fname (@$fnames) {
        my $sess = MT::Session->new;
        $sess->id( $app->make_magic_token() );
        $sess->kind('BU');    # BU == Backup
        $sess->name($fname);
        $sess->start(time);
        $sess->save;
    }
    my $message;
    if ( my $blog_id = $param->{blog_id} || $param->{blog_ids} ) {
        $message = $app->translate(
            "Blog(s) (ID:[_1]) was/were successfully backed up by user '[_2]'",
            $blog_id, $app->user->name
        );
    }
    else {
        $message
            = $app->translate(
            "Movable Type system was successfully backed up by user '[_1]'",
            $app->user->name );
    }
    $app->log(
        {   message  => $message,
            level    => MT::Log::INFO(),
            class    => 'system',
            category => 'restore'
        }
    );
    $app->print_encode(
        $app->build_page( 'include/backup_end.tmpl', $param ) );
}

sub _progress {
    my $app = shift;
    my $ids = $app->request('progress_ids') || {};

    my ( $str, $id ) = @_;
    if ( $id && $ids->{$id} ) {
        my $str_js = encode_js($str);
        $app->print_encode(
            qq{<script type="text/javascript">progress('$str_js', '$id');</script>}
        );
    }
    elsif ($id) {
        $ids->{$id} = 1;
        $app->print_encode(qq{\n<span id="$id">$str</span>});
    }
    else {
        $app->print_encode("<span>$str</span>");
    }

    $app->request( 'progress_ids', $ids );
}

sub _log_dirty_restore {
    my $app = shift;
    my ($deferred) = @_;
    my %deferred_by_class;
    for my $key ( keys %$deferred ) {
        my ( $class, $id ) = split( '#', $key );
        if ( exists $deferred_by_class{$class} ) {
            push @{ $deferred_by_class{$class} }, $id;
        }
        else {
            $deferred_by_class{$class} = [$id];

        }
    }
    while ( my ( $class_name, $ids ) = each %deferred_by_class ) {
        my $message = $app->translate(
            'Some [_1] were not restored because their parent objects were not restored.',
            $class_name
        );
        $app->log(
            {   message  => $message,
                level    => MT::Log::WARNING(),
                class    => 'system',
                category => 'restore',
                metadata => join( ', ', @$ids ),
            }
        );
    }
    1;
}

sub login_json {
    my $app = shift;
    return $app->json_result(1);
}

1;
