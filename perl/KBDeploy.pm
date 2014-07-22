package KBDeploy;

use strict;
use warnings;
use Config::IniFiles;
use Data::Dumper;
use FindBin;

use Carp;
use Exporter;

$KBDeploy::VERSION = "1.0";

use vars  qw(@ISA @EXPORT_OK);
use base qw(Exporter);

our @ISA    = qw(Exporter);
our @EXPORT = qw(read_config mysystem deploy_devcontainer start_service stop_service deploy_service myservices mkdocs);

our $cfg;
our $globaltag;
# repo is hash that points to the git repo.  It should work for both the
# service name in the config file as well as the git repo name
our %repo;
# This makes it easy to map from a git repo name to a service
# i.e.  user_and_job_state -> UserAndJobState
our %reponame2service;

# TODO: sometimes the service block name is different than the repo name.  Change this to a function.
our %reponame;
our $basedir=$FindBin::Bin;
$basedir=~s/config$//;

# Defaults and paths
#my $KB_DC="$KB_BASE/dev_container";
#my $KB_RT="$KB_BASE/runtime";
#my $MAKE_OPTIONS=$ENV{"MAKE_OPTIONS"};
#
#$KB_DEPLOY=$cfg->{$globaltag}->{deploydir} if (defined $cfg->{$globaltag}->{deploydir});
#$KB_DC=$cfg->{$globaltag}->{devcontainer} if (defined $cfg->{$globaltag}->{devcontainer});
#$KB_RT=$cfg->{$globaltag}->{runtime} if (defined $cfg->{$globaltag}->{runtime});

if (-e "$basedir/config/gitssh" ){
  $ENV{'GIT_SSH'}=$basedir."/config/gitssh";
}

sub maprepos {
  for my $s (keys %{$cfg->{services}}){
  #
    $repo{$s}=$cfg->{services}->{$s}->{giturl};
    die "Undefined giturl for $s" unless defined $repo{$s};
    my $reponame=$repo{$s};
    $reponame=~s/.*\///;
    # Provide the name for the both the service name and repo name
    $repo{$reponame}=$repo{$s};
    $reponame{$s}=$reponame;
    $reponame2service{$reponame}=$s;
  }
}

sub myservices {
  my $me=shift;
  my @sl;
  for my $s (keys %{$cfg->{services}}){
    next unless defined $cfg->{services}->{$s}->{host};
    push @sl,$s if ($cfg->{services}->{$s}->{host} eq $me);
  }
  return @sl;
}


sub read_config {
   my $file=shift;
   $globaltag=shift;
   my $mcfg=new Config::IniFiles( -file => $file) or die "Unable to open $file".$Config::IniFiles::errors[0];

   # Could use the tie option, but let's build it up ourselves

   for my $section ($mcfg->Sections()){
     if ($section eq $globaltag){
       foreach ($mcfg->Parameters($section)){
         $cfg->{$globaltag}->{$_}=$mcfg->val($section,$_);
       }
     }
     else {
       $cfg->{services}->{$section}->{mem}=$cfg->{$globaltag}->{mem};
       $cfg->{services}->{$section}->{cores}=$cfg->{$globaltag}->{cores};
       #$cfg->{services}->{$section}->{host}=$cfg->{$globaltag}->{basename}."-".$section;
       $cfg->{services}->{$section}->{urlname}=$section;
       $cfg->{services}->{$section}->{basedir}=$section;
       $cfg->{services}->{$section}->{giturl}=$cfg->{$globaltag}->{repobase}."/".$section;
       foreach ($mcfg->Parameters($section)){
         $cfg->{services}->{$section}->{$_}=$mcfg->val($section,$_);
       }
       if (! defined $cfg->{services}->{$section}->{type} || $cfg->{services}->{$section}->{type} ne 'lib'){
         push @{$cfg->{servicelist}},$section;
       }
     }
   }
   maprepos();
   return $cfg;
}

sub update_config {
   my $file=shift;
   my $section=shift;
   my $param=shift;
   my $value=shift;

   my $mcfg=new Config::IniFiles( -file => $file) or die "Unable to open $file".$Config::IniFiles::errors[0];

   if ( ! defined $mcfg->val($section,$param)){
     $mcfg->newval($section,$param,$value);
   }
   $mcfg->WriteConfig($file);
}


sub mysystem {
  foreach (@_){
    system($_) eq 0 or die "Failed on $_ in $0\n";
  }
}

# Helper function to clone a module and checkout a tag.
sub clonetag {
  my $package=shift;
  my $mytag=shift;

  $mytag="head" if ! defined $mytag; 
  $mytag=$cfg->{$globaltag}->{tag} if defined $cfg->{$globaltag}->{tag};
  print "$package $mytag\n";

  print "- Cloning $package\n";
  if ( -e $package ) {
    chdir $package;
    # Make sure we are on head
    mysystem("git checkout master  > /dev/null 2>&1");
    mysystem("git pull  > /dev/null 2>&1");
    chdir("../");
  }
  else {
    mysystem("git clone $repo{$package} > /dev/null 2>&1");
  }
  if ( $mytag ne "head" ) {
    chdir $package;
    mysystem("git checkout \"$mytag\" > /dev/null 2>&1");
    chdir "../";
  }
  # Save the stats
  my $hash=`cd $package;git log --pretty='%H' -n 1`;
  chomp $hash;
  my $hf=$cfg->{$globaltag}->{devcontainer}."/".$cfg->{$globaltag}->{hashfile};
  open GH,">> $hf" or die "Unable to create $hf\n";
  print GH "$reponame2service{$package} $repo{$package} $hash\n";
  close GH;
}

# Recursively get dependencies
#
sub getdeps {
  my $mserv=shift;
  my $KB_DC=$cfg->{$globaltag}->{devcontainer};
  print "- Processing dependencies for $mserv\n";
  $mserv=$reponame{$mserv} if defined $reponame{$mserv};

  my $DEP="$KB_DC/modules/$mserv/DEPENDENCIES";
  return if ( ! -e "$DEP" );

  my @deps;
  open(D,$DEP) or die "Unable to open $DEP";
  while (<D>){
    chomp;
    push @deps,$_;
  }
  close D;

  foreach $_ (@deps){
    if ( ! -e "$KB_DC/modules/$_" ) {
      clonetag($_);
      getdeps($_);
    }
  }
}

# Deploy the Dev Container
#
sub deploy_devcontainer {
  my $LOGFILE=shift;
  my $KB_DC=$cfg->{$globaltag}->{devcontainer};
  my $KB_RT=$cfg->{$globaltag}->{runtime};
  my $MAKE_OPTIONS="";

  my $KB_BASE=$KB_DC;
  # Strip off last
  $KB_BASE=~s/.dev_container//;
  mkdir $KB_BASE;
  chdir $KB_BASE;
  clonetag "dev_container";
  chdir "dev_container/modules";

  for my $pack ("kbapi_common","typecomp","jars","auth" ) {
    clonetag $pack;
  }
  chdir("$KB_DC");
  mysystem("./bootstrap $KB_RT");

  # Fix up setup
  mysystem("$basedir/config/fixup_dc");
 
  print "Running Make in dev_container\n";
  mysystem(". ./user-env.sh;make $MAKE_OPTIONS >> $LOGFILE");

  print "Running make deploy\n";
  mysystem(". ./user-env.sh;make deploy $MAKE_OPTIONS >> $LOGFILE");
  print "====\n";
}

# Start service helper function
#
sub start_service {
  my $KB_DEPLOY=$cfg->{$globaltag}->{deploydir};
  for my $s (@_)  {
    my $spath=$s;
    $spath=$cfg->{services}->{$s}->{basedir} if (defined $cfg->{services}->{$s}->{basedir});
    if ( -e "$KB_DEPLOY/services/$spath/start_service" ) {
      mysystem(". $KB_DEPLOY/user-env.sh;$KB_DEPLOY/services/$spath/start_service");
    }
    else {
      print "No start script found in $s\n";
    }
  }
}


# Stop Services
#
sub stop_service {
  my $KB_DEPLOY=$cfg->{$globaltag}->{deploydir};
  for my $s (@_) {
    my $spath=$s;
    $spath=$cfg->{services}->{$s}->{basedir} if defined $cfg->{services}->{$s}->{basedir};
    if ( -e "$KB_DEPLOY/services/$spath/stop_service"){
      mysystem(". $KB_DEPLOY/user-env.sh;$KB_DEPLOY/services/$spath/stop_service || echo Ignore");
    }
  }
}

sub prepare_service {
  my $LOGFILE=shift;
  my $KB_DC=shift;

  chdir "$KB_DC/modules";
  for my $mserv (@_) {
    print "Deploying $mserv\n";
    # Clone or update the module
    clonetag $mserv;
    # Now get any dependencies
    getdeps $mserv;
  }
}

sub readhashes {
  my $f=shift;
  open(H,$f);
  while(<H>){
    chomp;
    my ($s,$url,$hash)=split;
    $cfg->{services}->{$s}->{hash}=$hash;
    my $confurl=$cfg->{services}->{$s}->{giturl};
    print STDERR "Warning: different git url for service $s\n" if $confurl ne $url;
    print STDERR "Warning: $confurl vs $url\n" if $confurl ne $url;
    $cfg->{services}->{$s}->{hash}=$hash;
    $cfg->{services}->{$s}->{giturl}=$url;
  }
  close H;
}

sub redeploy_service {
  my $tagfile=shift; 

  die unless -e $tagfile;
  readhashes($tagfile);
# Check hashes

  my $hf=$cfg->{$globaltag}->{devcontainer}."/".$cfg->{$globaltag}->{hashfile};
  if (! open(H,"$hf")){
    print STDERR "Missing hash file $hf\n";
    return 1;
  }
  while(<H>){
    chomp;
    my ($s,$url,$hash)=split;
    return 1 if $url ne $cfg->{services}->{$s}->{giturl};
  }
 
  return 0;
}

sub deploy_service {
  my $LOGFILE="/tmp/deploy.log";
  my $KB_DEPLOY=$cfg->{$globaltag}->{deploydir};
  my $KB_DC=$cfg->{$globaltag}->{devcontainer};
  my $KB_RT=$cfg->{$globaltag}->{runtime};
  my $skipdeploy=0;

  # Extingush all traces of previous deployments
  my $d=`date +%s`;
  chomp $d;
  rename($KB_DEPLOY,"$KB_DEPLOY.$d") if -e $KB_DEPLOY;
  mysystem("rm -rf $KB_DC") if (-e $KB_DC);

  # Empty log file
  unlink $LOGFILE if ( -e $LOGFILE );

  # Create the dev container and some common dependencies
  deploy_devcontainer($LOGFILE) unless ( -e "$KB_DEPLOY/bin/compile_typespec" );

  if ($_[0] eq 'skipdeploy') {
    shift @_;
    $skipdeploy=1; 
  }
  prepare_service($LOGFILE,$KB_DC,@_);
  chdir("$KB_DC");

  print "Starting bootstrap $KB_DC\n";
  mysystem("./bootstrap $KB_RT");
  # Fix up setup
  mysystem("$basedir/config/fixup_dc");

  # Copy the deployment config from the reference copy
  mysystem("cp $basedir/cluster.ini $KB_DEPLOY/deployment.cfg");

  print "Running make\n";
  mysystem(". $KB_DC/user-env.sh;make >> $LOGFILE 2>&1");

  if (! $skipdeploy){
    print "Running make deploy\n";
    mysystem(". $KB_DC/user-env.sh;make deploy >> $LOGFILE 2>&1");
  }

}

sub gittag {
  my $service=shift;
  
  my $repo=$repo{$service};
  my $tag=`git ls-remote $repo HEAD`;
  chomp $tag;
  $tag=~s/\tHEAD//;
  return $tag;
}

sub mkdocs {
  my $KB_DEPLOY=$cfg->{$globaltag}->{deploydir};
  for my $s (@_){
    my $bd=$cfg->{services}->{$s}->{basedir};
    symlink $KB_DEPLOY."/services/$bd/webroot","/var/www/$bd";
  } 
}


1;