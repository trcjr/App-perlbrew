package App::perlbrew;
use strict;
use warnings;
use 5.008;
use Getopt::Long ();
use File::Spec::Functions qw( catfile );

our $VERSION = "0.16";
our $CONF;

my $ROOT         = $ENV{PERLBREW_ROOT} || "$ENV{HOME}/perl5/perlbrew";
my $CONF_FILE    = catfile( $ROOT, 'Conf.pm' );
my $CURRENT_PERL = $ENV{PERLBREW_PERL};

sub current_perl { $CURRENT_PERL || '' }

sub BASHRC_CONTENT() {
    return <<'RC';
if [[ -f $HOME/.perlbrew/init ]]; then
    source $HOME/.perlbrew/init
fi

short_option=""

__perlbrew_reinit () {
    if [[ ! -d $HOME/.perlbrew ]]; then
        mkdir -p $HOME/.perlbrew
    fi

    echo '# DO NOT EDIT THIS FILE' > $HOME/.perlbrew/init
    command perlbrew $short_option env $1 >> $HOME/.perlbrew/init
    source $HOME/.perlbrew/init
    __perlbrew_set_path
}

__perlbrew_set_path () {
    [[ -z "$PERLBREW_ROOT" ]] && return 1
    hash -d perl 2>/dev/null
    export PATH_WITHOUT_PERLBREW=$(perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_ROOT}) } split/:/,$ENV{PATH};')
    export PATH=$PERLBREW_PATH:$PATH_WITHOUT_PERLBREW
}
__perlbrew_set_path

perlbrew () {
    local exit_status
    export SHELL

    if [[ `echo $1 | awk 'BEGIN{FS=""}{print $1}'` = '-' ]]; then
        short_option=$1
        shift
    fi

    case $1 in
        (use)
            if [[ -z "$2" ]] ; then
                if [[ -z "$PERLBREW_PERL" ]] ; then
                    echo "No version in use; defaulting to system"
                else
                    echo "Using $PERLBREW_PERL version"
                fi
            elif [[ -x "$PERLBREW_ROOT/perls/$2/bin/perl" || "$2" = "system" ]]; then
                unset PERLBREW_PERL
                eval $(command perlbrew $short_option env $2)
                __perlbrew_set_path
            else
                echo "$2 is not installed" >&2
                exit_status=1
            fi
            ;;

        (switch)
              command perlbrew $short_option $*
              exit_status=$?

              if [[ -n "$2" ]] ; then
                  __perlbrew_reinit
              fi
              ;;

        (off)
            unset PERLBREW_PERL
            command perlbrew $short_option off

            __perlbrew_reinit
            ;;

        (*)
            command perlbrew $short_option $*
            exit_status=$?
            ;;
    esac
    hash -r
    return ${exit_status:-0}
}

RC

}

# File::Path::Tiny::mk
sub mkpath {
    my ($path,$mask) = @_;
    return 2 if -d $path;
    if (-e $path) { $! = 20;return; }
    $mask ||= '0777'; # Perl::Critic == Integer with leading zeros at ...
    $mask = oct($mask) if substr($mask,0,1) eq '0';
    require File::Spec;
    my ($progressive, @parts) = File::Spec->splitdir($path);
    if (!$progressive) {
        $progressive = File::Spec->catdir($progressive, shift(@parts));
    }
    if(!-d $progressive) {
        mkdir($progressive, $mask) or return;
    }
    for my $part (@parts) {
        $progressive = File::Spec->catdir($progressive,$part);
        if (!-d $progressive) {
            mkdir($progressive, $mask) or return;
        }
    }
    return 1 if -d $path;
    return;
}

sub uniq(@) {
    my %a;
    grep { ++$a{$_} == 1 } @_;
}

{
    my @command;
    sub http_get {
        my ($url, $header, $cb) = @_;

        if (ref($header) eq 'CODE') {
            $cb = $header;
            $header = undef;
        }

        if (! @command) {
            my @commands = (
                [qw( curl --silent --location )],
                [qw( wget --no-check-certificate --quiet -O - )],
            );
            for my $command (@commands) {
                my $program = $command->[0];
                if (! system("$program --version >/dev/null 2>&1")) {
                    @command = @$command;
                    last;
                }
            }
            die "You have to install either curl or wget\n"
                unless @command;
        }

        open my $fh, '-|', @command, $url
            or die "open() for '@command $url': $!";
        local $/;
        my $body = <$fh>;
        close $fh;

        return $cb ? $cb->($body) : $body;
    }
}

sub new {
    my($class, @argv) = @_;

    my %opt = (
        force => 0,
        quiet => 1,
        D => [],
        U => [],
        A => [],
    );

    # build a local @ARGV to allow us to use an older
    # Getopt::Long API in case we are building on an older system
    local (@ARGV) = @argv;

    Getopt::Long::Configure(
        'pass_through',
        'no_ignore_case',
        'bundling',
    );

    Getopt::Long::GetOptions(
        \%opt,

        'force|f!',
        'notest|n!',
        'quiet|q!',
        'verbose|v',
        'as=s',
        'help|h',
        'version',
        # options passed directly to Configure
        'D=s@',
        'U=s@',
        'A=s@',

        'j=i'
    )
      or run_command_help(1);

    # fix up the effect of 'bundling'
    foreach my $flags (@opt{qw(D U A)}) {
        foreach my $value(@{$flags}) {
            $value =~ s/^=//;
        }
    }

    $opt{args} = \@ARGV;

    return bless \%opt, $class;
}

sub env {
    my ($self, $name) = @_;
    return $ENV{$name} if $name;
    return \%ENV;
}

sub is_shell_csh {
    my ($self) = @_;
    return 1 if $self->env('SHELL') =~ /(t?csh)/;
    return 0;
}

sub run {
    my($self) = @_;
    $self->run_command($self->get_args);
}

sub get_args {
    my ( $self ) = @_;
    return @{ $self->{args} };
}

sub run_command {
    my ( $self, $x, @args ) = @_;
    $self->{log_file} ||= "$ROOT/build.log";
    if($self->{version}) {
        $x = 'version';
    }
    elsif(!$x) {
        $x = 'help';
        @args = (0, $self->{help} ? 2 : 0);
    }
    elsif($x eq 'help') {
        @args = (0, 2);
    }

    my $s = $self->can("run_command_$x");
    unless ($s) {
        $x =~ s/-/_/;
        $s = $self->can("run_command_$x");
    }

    die "Unknown command: `$x`. Typo?\n" unless $s;
    $self->$s(@args);
}

sub run_command_version {
    my ( $self ) = @_;
    my $package = ref $self;
    my $version = $self->VERSION;
    print <<"VERSION";
$0  - $package/$version
VERSION
}

sub run_command_help {
    my ($self, $status, $verbose) = @_;
    require Pod::Usage;
    Pod::Usage::pod2usage(-verbose => $verbose||0, -exitval => (defined $status ? $status : 1));
}

sub run_command_init {
    my $self = shift;
    my $HOME = $self->env('HOME');

    mkpath($_) for (
        "$HOME/.perlbrew",
        "$ROOT/perls", "$ROOT/dists", "$ROOT/build", "$ROOT/etc",
        "$ROOT/bin"
    );

    open BASHRC, "> $ROOT/etc/bashrc";
    print BASHRC BASHRC_CONTENT;

    system <<RC;
echo 'setenv PATH $ROOT/bin:$ROOT/perls/current/bin:\$PATH' > $ROOT/etc/cshrc
RC

    my ( $shrc, $yourshrc );
    if ( $self->is_shell_csh) {
        $shrc     = 'cshrc';
        $yourshrc = $1 . "rc";
    }
    else {
        $shrc = $yourshrc = 'bashrc';
    }


    system("$0 env > ${HOME}/.perlbrew/init");

    print <<INSTRUCTION;
Perlbrew environment initiated, required directories are created under

    $ROOT

Well-done! Congratulations! Please add the following line to the end
of your ~/.${yourshrc}

    source $ROOT/etc/${shrc}

After that, exit this shell, start a new one, and install some fresh
perls:

    perlbrew install perl-5.12.1
    perlbrew install perl-5.10.1

For further instructions, simply run:

    perlbrew

The default help messages will popup and tell you what to do!

Enjoy perlbrew at \$HOME!!
INSTRUCTION

}

sub run_command_install {
    my ( $self, $dist, $opts ) = @_;

    unless ($dist) {
        require File::Copy;

        my $executable = $0;

        unless (File::Spec->file_name_is_absolute($executable)) {
            $executable = File::Spec->rel2abs($executable);
        }

        my $target = catfile($ROOT, "bin", "perlbrew");
        if ($executable eq $target) {
            print "You are already running the installed perlbrew:\n\n    $executable\n";
            exit;
        }

        mkpath("$ROOT/bin");
        File::Copy::copy($executable, $target);
        chmod(0755, $target);

        print <<HELP;
The perlbrew is installed as:

    $target

You may trash the downloaded $executable from now on.

Next, if this is the first time you install perlbrew, run:

    $target init

And follow the instruction on screen.
HELP

        return;
    }

    my ($dist_name, $dist_version) = $dist =~ m/^(.*)-([\d.]+(?:-RC\d+)?|git)$/;
    my $dist_git_describe;

    if (-d $dist && !$dist_name || !$dist_version) {
        if (-d "$dist/.git") {
            if (`git describe` =~ /v((5\.\d+\.\d+)(-\d+-\w+)?)$/) {
                $dist_name = "perl";
                $dist_git_describe = "v$1";
                $dist_version = $2;
            }
        }
        else {
            print <<HELP;

The given directory $dist is not a git checkout of perl repository. To
brew a perl from git, clone it first:

    git clone git://github.com/mirrors/perl.git
    perlbrew install perl

HELP
                return;
        }
    }

    if ($dist_name eq 'perl') {
        my ($dist_path, $dist_tarball, $dist_commit);

        unless ($dist_git_describe) {
            my $mirror = $self->conf->{mirror};
            my $header = $mirror ? { 'Cookie' => "cpan=$mirror->{url}" } : undef;
            my $html = http_get("http://search.cpan.org/dist/$dist", $header);

            ($dist_path, $dist_tarball) =
                $html =~ m[<a href="(/CPAN/authors/id/.+/(${dist}.tar.(gz|bz2)))">Download</a>];

            my $dist_tarball_path = "${ROOT}/dists/${dist_tarball}";
            if (-f $dist_tarball_path) {
                print "Use the previously fetched ${dist_tarball}\n";
            }
            else {
                print "Fetching $dist as $dist_tarball_path\n";

                http_get(
                    "http://search.cpan.org${dist_path}",
                    $header,
                    sub {
                        my ($body) = @_;
                        open my $BALL, "> $dist_tarball_path";
                        print $BALL $body;
                        close $BALL;
                    }
                );
            }

        }

        my @d_options = @{ $self->{D} };
        my @u_options = @{ $self->{U} };
        my @a_options = @{ $self->{A} };
        my $as = $self->{as} || ($dist_git_describe ? "perl-$dist_git_describe" : $dist);
        unshift @d_options, qq(prefix=$ROOT/perls/$as);
        push @d_options, "usedevel" if $dist_version =~ /5\.1[13579]|git/ ? "-Dusedevel" : "";
        print "Installing $dist into $ROOT/perls/$as\n";
        print <<INSTALL if $self->{quiet} && !$self->{verbose};
This could take a while. You can run the following command on another shell to track the status:

  tail -f $self->{log_file}

INSTALL

        my ($extract_command, $configure_flags) = ("", "-des");

        my $dist_extracted_dir;
        if ($dist_git_describe) {
            $extract_command = "echo 'Building perl in the git checkout dir'";
            $dist_extracted_dir = File::Spec->rel2abs( $dist );
        } else {
            $dist_extracted_dir = "$ROOT/build/${dist}";

            # Was broken on Solaris, where GNU tar is probably
            # installed as 'gtar' - RT #61042
            my $tarx = ($^O eq 'solaris' ? 'gtar ' : 'tar ') . ( $dist_tarball =~ /bz2/ ? 'xjf' : 'xzf' );
            $extract_command = "cd $ROOT/build; $tarx $ROOT/dists/${dist_tarball}";
            $configure_flags = '-de';
        }

        # Test via "make test_harness" if available so we'll get
        # automatic parallel testing via $HARNESS_OPTIONS. The
        # "test_harness" target was added in 5.7.3, which was the last
        # development release before 5.8.0.
        my $test_target = "test";
        if ($dist_version =~ /^5\.(\d+)\.(\d+)/
            && ($1 >= 8 || $1 == 7 && $2 == 3)) {
            $test_target = "test_harness";
        }

        my $make = "make " . ($self->{j} ? "-j$self->{j}" : "");
        my @install = $self->{notest} ? "make install" : ("make $test_target", "make install");
        @install    = join " && ", @install unless($self->{force});

        my $cmd = join ";",
        (
            $extract_command,
            "cd $dist_extracted_dir",
            "rm -f config.sh Policy.sh",
            "sh Configure $configure_flags " .
                join( ' ',
                    ( map { qq{'-D$_'} } @d_options ),
                    ( map { qq{'-U$_'} } @u_options ),
                    ( map { qq{'-A$_'} } @a_options ),
                ),
            $dist_version =~ /^5\.(\d+)\.(\d+)/
                && ($1 < 8 || $1 == 8 && $2 < 9)
                    ? ("$^X -i -nle 'print unless /command-line/' makefile x2p/makefile")
                    : (),
            $make,
            @install
        );
        $cmd = "($cmd) >> '$self->{log_file}' 2>&1 "
            if ( $self->{quiet} && !$self->{verbose} );


        print $cmd, "\n";

        delete $ENV{$_} for qw(PERL5LIB PERL5OPT);

        if (!system($cmd)) {
            print <<SUCCESS;
Installed $dist as $as successfully. Run the following command to switch to it.

  perlbrew switch $as

SUCCESS
        }
        else {
            print <<FAIL;
Installing $dist failed. See $self->{log_file} to see why.
If you want to force install the distribution, try:

  perlbrew --force install $dist_name

FAIL
        }
    }
}

sub format_perl_version {
    my $self    = shift;
    my $version = shift;
    return sprintf "%d.%d.%d",
      substr( $version, 0, 1 ),
      substr( $version, 2, 3 ),
      substr( $version, 5 );

}

sub installed_perls {
    my $self    = shift;
    my $current = readlink("$ROOT/perls/current");

    my @result;

    for (<$ROOT/perls/*>) {
        next if m/current/;
        my ($name) = $_ =~ m/\/([^\/]+$)/;
        push @result, { name => $name, is_current => (current_perl eq $name) };
    }

    my $current_perl_executable = readlink("$ROOT/bin/perl") || `which perl`;
    $current_perl_executable =~ s/\n$//;

    my $current_perl_executable_version;
    for ( uniq grep { -f $_ && -x $_ } map { "$_/perl" } split(":", $self->env('PATH')) ) {
        $current_perl_executable_version =
          $self->format_perl_version(`$_ -e 'print \$]'`);
        push @result, {
            name => $_ . " (" . $current_perl_executable_version . ")",
            is_current => $current_perl_executable && ($_ eq $current_perl_executable)
        } unless index($_, $ROOT) == 0;
    }

    return @result;
}

# Return a hash of PERLBREW_* variables
sub perlbrew_env {
    my ($self, $perl) = @_;

    my %env = (
        PERLBREW_VERSION => $VERSION,
        PERLBREW_PATH => "$ROOT/bin",
        PERLBREW_ROOT => $ROOT
    );

    if ($perl) {
        if(-d "$ROOT/perls/$perl/bin") {
            $env{PERLBREW_PERL} = $perl;
            $env{PERLBREW_PATH} .= ":$ROOT/perls/$perl/bin";
        }
    }
    elsif (-d "$ROOT/perls/current/bin") {
        $env{PERLBREW_PERL} = readlink("$ROOT/perls/current");
        $env{PERLBREW_PATH} .= ":$ROOT/perls/current/bin";
    }

    return %env;
}

sub run_command_list {
    my $self = shift;

    for my $i ( $self->installed_perls ) {
        print $i->{is_current} ? '* ': '  ', $i->{name}, "\n";
    }
}

sub run_command_use {
    my $self = shift;

    if ($self->is_shell_csh) {
        my $shell = $self->env('SHELL');
        print "You shell '$shell' does not support the 'use' command at this time\n";
        exit(1);
    }

    print <<WARNING;
Your perlbrew setup is not complete!

Please make sure you run `perlbrew init` first and follow the
instructions, specially the bits about changing your .bashrc
and exiting the current terminal and starting a new one.

WARNING
}

sub run_command_switch {
    my ( $self, $dist, $alias ) = @_;

    unless ( $dist ) {
        # If no args were given to switch, show the current perl.
        my $current = readlink ( -d "$ROOT/perls/current"
                                 ? "$ROOT/perls/current"
                                 : "$ROOT/bin/perl" );
        printf "Currently switched %s\n",
            ( $current ? "to $current" : 'off' );
        return;
    }

    die "Cannot use for alias something that starts with 'perl-'\n"
      if $alias && $alias =~ /^perl-/;

    my $vers = $dist;
    if (-x $dist) {
        $alias = 'custom' unless $alias;
        my $bin_dir = "$ROOT/perls/$alias/bin";
        my $perl = catfile($bin_dir, 'perl');
        mkpath($bin_dir);
        unlink $perl;
        symlink $dist, $perl;
        $dist = $alias;
        $vers = "$vers as $alias";
    }

    die "${dist} is not installed\n" unless -d "$ROOT/perls/${dist}";
    chdir "$ROOT/perls";
    unlink "current";
    symlink $dist, "current";
    print "Switched to $vers\n";
}

sub run_command_off {
    local $_ = "$ROOT/perls/current";
    unlink if -l;
    for my $executable (<$ROOT/bin/*>) {
        unlink($executable) if -l $executable;
    }
}

sub run_command_mirror {
    my($self) = @_;
    print "Fetching mirror list\n";
    my $raw = http_get("http://search.cpan.org/mirror");
    my $found;
    my @mirrors;
    foreach my $line ( split m{\n}, $raw ) {
        $found = 1 if $line =~ m{<select name="mirror">};
        next if ! $found;
        last if $line =~ m{</select>};
        if ( $line =~ m{<option value="(.+?)">(.+?)</option>} ) {
            my $url  = $1;
            (my $name = $2) =~ s/&#(\d+);/chr $1/seg;
            push @mirrors, { url => $url, name => $name };
        }
    }

    my $select;
    require ExtUtils::MakeMaker;
    MIRROR: foreach my $id ( 0..$#mirrors ) {
        my $mirror = $mirrors[$id];
        printf "[% 3d] %s\n", $id + 1, $mirror->{name};
        if ( $id > 0 ) {
            my $test = $id / 19;
            if ( $test == int $test ) {
                my $remaining = $#mirrors - $id;
                my $ask = "Select a mirror by number or press enter to see the rest "
                        . "($remaining more) [q to quit, m for manual entry]";
                my $val = ExtUtils::MakeMaker::prompt( $ask );
                next MIRROR if ! $val;
                last MIRROR if $val eq 'q';
                $select = $val;
		if($select eq 'm') {
                    my $url  = ExtUtils::MakeMaker::prompt("Enter the URL of your CPAN mirror:");
		    my $name = ExtUtils::MakeMaker::prompt("Enter a Name: [default: My CPAN Mirror]") || "My CPAN Mirror";
		    $select = { name => $name, url => $url };
		}
                elsif ( ! $select || $select - 1 > $#mirrors ) {
                    die "Bogus mirror ID: $select";
                }
                $select = $mirrors[$select - 1] unless ($select eq 'm');
                die "Mirror ID is invalid" if ! $select;
                last MIRROR;
            }
        }
    }
    die "You didn't select a mirror!\n" if ! $select;
    print "Selected $select->{name} ($select->{url}) as the mirror\n";
    my $conf = $self->conf;
    $conf->{mirror} = $select;
    $self->_save_conf;
    return;
}

sub run_command_env {
    my($self, $perl) = @_;

    my %env = $self->perlbrew_env($perl);

    if ($self->env('SHELL') =~ /(ba|z|\/)sh$/) {
        while (my ($k, $v) = each(%env)) {
            print "export $k=$v\n";
        }
    }
    else {
        while (my ($k, $v) = each(%env)) {
            print "setenv $k $v\n";
        }
    }
}

sub run_command_symlink_executables {
    ## Ignore it silently for now
}

sub run_command_install_cpanm {
    my ($self, $perl) = @_;
    my $body = http_get('https://github.com/miyagawa/cpanminus/raw/master/cpanm');

    open my $CPANM, '>', "$ROOT/bin/cpanm" or die "cannot open file($ROOT/bin/cpanm): $!";
    print $CPANM $body;
    close $CPANM;
    chmod 0755, "$ROOT/bin/cpanm";
    print "cpanm is installed to $ROOT/bin/cpanm\n" if $self->{verbose};
}

sub run_command_exec {
    my ($self, @args) = @_;

    for my $i ( $self->installed_perls ) {
        my %env = $self->perlbrew_env($i->{name});
        my $command = "";

        while ( my($name, $value) = each %env) {
            $command .= "$name=$value ";
        }

        $command .= ' PATH=${PERLBREW_PATH}:${PATH} ';
        $command .= "; " . join " ", map { quotemeta($_) } @args;

        print "$i->{name}\n==========\n";
        system "$command\n";
        print "\n\n";
        # print "\n<===\n\n\n";
    }
}


sub conf {
    my($self) = @_;
    $self->_get_conf if ! $CONF;
    return $CONF;
}

sub _save_conf {
    my($self) = @_;
    require Data::Dumper;
    open my $FH, '>', $CONF_FILE or die "Unable to open conf ($CONF_FILE): $!";
    my $d = Data::Dumper->new([$CONF],['App::perlbrew::CONF']);
    print $FH $d->Dump;
    close $FH;
}

sub _get_conf {
    my($self) = @_;
    print "Attempting to load conf from $CONF_FILE\n";
    if ( ! -e $CONF_FILE ) {
        local $CONF = {} if ! $CONF;
        $self->_save_conf;
    }

    open my $FH, '<', $CONF_FILE or die "Unable to open conf ($CONF_FILE): $!";
    my $raw = do { local $/; my $rv = <$FH>; $rv };
    close $FH;

    my $rv = eval $raw;
    if ( $@ ) {
        warn "Error loading conf: $@";
        $CONF = {};
        return;
    }
    $CONF = {} if ! $CONF;
    return;
}

1;

__END__

=encoding utf8

=head1 NAME

App::perlbrew - Manage perl installations in your $HOME

=head1 SYNOPSIS

    # Initialize
    perlbrew init

    # Pick a preferred CPAN mirror
    perlbrew mirror

    # Install some Perls
    perlbrew install perl-5.12.2
    perlbrew install perl-5.8.1
    perlbrew install perl-5.13.6

    # See what were installed
    perlbrew list

    # Switch perl in the $PATH
    perlbrew switch perl-5.12.2
    perl -v

    # Switch to another version
    perlbrew switch perl-5.8.1
    perl -v

    # Switch to a certain perl executable not managed by perlbrew.
    perlbrew switch /usr/bin/perl

    # Or turn it off completely. Useful when you messed up too deep.
    perlbrew off

    # Use 'switch' command to turn it back on.
    perlbrew switch perl-5.12.2

=head1 DESCRIPTION

perlbrew is a program to automate the building and installation of
perl in the users HOME. At the moment, it installs everything to
C<~/perl5/perlbrew>, and requires you to tweak your PATH by including a
bashrc/cshrc file it provides. You then can benefit from not having
to run 'sudo' commands to install cpan modules because those are
installed inside your HOME too. It's a completely separate perl
environment.

=head1 INSTALLATION

To use C<perlbrew>, it is required to install C<curl> or C<wget>
first. C<perlbrew> depends on one of this two external commmands to be
there in order to fetch files from the internet.

The recommended way to install perlbrew is to run these statements in
your shell:

    curl -LO http://xrl.us/perlbrew
    chmod +x perlbrew
    ./perlbrew install

or more simply:

    curl -L http://xrl.us/perlbrewinstall | bash

After that, C<perlbrew> installs itself to C<~/perl5/perlbrew/bin>,
and you should follow the instruction on screen to setup your
C<.bashrc> or C<.cshrc> to put it in your PATH.

The directory C<~/perl5/perlbrew> will contain all install perl
executables, libraries, documentations, lib, site_libs. If you need to
install C<perlbrew>, and the perls it brews, into somewhere else
because, say, your HOME has limited quota, you can do that by setting
a C<PERLBREW_ROOT> environment variable before you run C<./perlbrew install>.

    export PERLBREW_ROOT=/mnt/perlbrew
    ./perlbrew install

The downloaded perlbrew is a self-contained standalone program that
embeds all non-core modules it uses. It should be runnable with perl
5.8 or later versions of perl.

You may also install perlbrew from CPAN with cpan / cpanp / cpanm:

    cpan App::perlbrew

This installs 'perlbrew' into your current PATH and it is always
executed with your current perl.

NOTICE. When you install or upgrade perlbrew with cpan / cpanp /
cpanm, make sure you are not using one of the perls brewed with
perlbrew. If so, the `perlbrew` executable you just installed will not
be available after you switch to other perls. You might not be able to
invoke further C<perlbrew> commands after so because the executable
C<perlbrew> is not in your C<PATH> anymore. Installing it again with
cpan can temporarily solve this problem. To ensure you are not using
a perlbrewed perl, run C<perlbrew off> before upgrading.


It should be relatively safe to install C<App::perlbrew> with system
cpan (like C</usr/bin/cpan>) because then it will be installed under a
system PATH like C</usr/bin>, which is not affected by C<perlbrew switch>
command.

Again, it is recommended to let C<perlbrew> install itself. It's
easier, and it works better.

=head1 USAGE

Please read the program usage by running

    perlbrew

(No arguments.) To read a more detailed one:

    perlbrew -h

=head1 PROJECT DEVELOPMENT

perlbrew project uses github
L<http://github.com/gugod/App-perlbrew/issues> and RT
<https://rt.cpan.org/Dist/Display.html?Queue=App-perlbrew> for issue
tracking. Issues sent to these two systems will eventually be reviewed
and handled.

=head1 AUTHOR

Kang-min Liu  C<< <gugod@gugod.org> >>

=head1 COPYRIGHT

Copyright (c) 2010, Kang-min Liu C<< <gugod@gugod.org> >>.

=head1 LICENCE

The MIT License

=head1 CONTRIBUTORS

Patches and code improvements have been contributed by:

Tatsuhiko Miyagawa, Chris Prather, Yanick Champoux, aero, Jason May,
Jesse Leuhrs, Andrew Rodland, Justin Davis, Masayoshi Sekimura,
castaway, jrockway, chromatic, Goro Fuji, Sawyer X, Danijel Tasov,
polettix, tokuhirom, Ævar Arnfjörð Bjarmason.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
