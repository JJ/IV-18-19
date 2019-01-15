# -*- cperl -*-

BEGIN { # Hay que poner estos módulos _al final_ para que no fastidien si no están en debian
  for my $path (qw(/usr/lib /usr/local/lib /usr/share/perl5 /usr/lib/x86_64-linux-gnu/perl5/5.24/) ){ # Necesarios para paquetes Debian
    push( @INC, $path)
  }
}

use Test::More;
use Git;
use Mojo::UserAgent;
use File::Slurper qw(read_text);
use JSON;
use Net::Ping;
use Term::ANSIColor qw(:constants);
# use Net::SSLeay;
# use IO::Socket::SSL;


use v5.14; # For say

my $repo = Git->repository ( Directory => '.' );
my $diff = $repo->command('diff','HEAD^1','HEAD');
my $diff_regex = qr/a\/proyectos\/hito-(\d)\.md/;
my $ua =  Mojo::UserAgent->new(connect_timeout => 10);
my $github;

SKIP: {
  my ($this_hito) = ($diff =~ $diff_regex);
  skip "No hay envío de proyecto" unless defined $this_hito;
  my @files = split(/diff --git/,$diff);

  my ($diff_hito) = grep( /$diff_regex/, @files);
  say "Tratando diff\n\t$diff_hito";
  my @lines = split("\n",$diff_hito);
  my @adds = grep(/^\+[^+]/,@lines);
  is( $#adds, 0, "Añade sólo una línea"); # Test 1
  my $url_repo;
  if ( $adds[0] =~ /\(http/ ) {
    ($url_repo) = ($adds[0] =~ /\((http\S+)\)/);
  } else {
    ($url_repo) = ($adds[0] =~ /^\+.+(http\S+)/s);
  }
  say $url_repo;
  isnt($url_repo,"","El envío incluye un URL"); # Test 2
  like($url_repo,qr/github.com/,"El URL es de GitHub"); # Test 3
  my ($user,$name) = ($url_repo=~ /github.com\/(\S+)\/([^\.]+)/);

  # Comprobación de envío de objetivos cuando hay nombre de usuario
  my $prefix = ($repo->{'opts'}->{'WorkingSubdir'} eq 't/')?"..":".";
  my @ficheros_objetivos = glob "$prefix/objetivos/*.md";
  my ($este_fichero) =  grep( /$user/i, @ficheros_objetivos);
  isnt( $este_fichero, "$user ha enviado objetivos" ); # Test 4

  # Comprobar que los ha actualizado
  ok( objetivos_actualizados( $repo, $este_fichero ),
      "Fichero de objetivos $este_fichero está actualizado") or skip "Los objetivos no están actualizados";

  # Se crea el repo y se hacen cosas.
  my $repo_dir = "/tmp/$user-$name";
  if (!(-e $repo_dir) or  !(-d $repo_dir) ) {
    mkdir($repo_dir);
    `git clone $url_repo $repo_dir`;
  }
  my $student_repo =  Git->repository ( Directory => $repo_dir );
  my @repo_files = $student_repo->command("ls-files");
  say "Ficheros\n\t→", join( "\n\t→", @repo_files);

  for my $f (qw( README.md \.gitignore LICENSE )) { # Tests 5-7
    isnt( grep( /$f/, @repo_files), 0, "$f presente" );
  }


  if ( $this_hito > 0 ) { # Comprobar milestones y eso
    doing("hito 1");
    cmp_ok( how_many_milestones( $user, $name), ">=", 3, "Número de hitos correcto");

    my @closed_issues =  closed_issues($user, $name);
    cmp_ok( $#closed_issues , ">=", 0, "Hay ". scalar(@closed_issues). " issues cerrado(s)");
    for my $i (@closed_issues) {
      my ($issue_id) = ($i =~ /(\d+)/);
      is(closes_from_commit($user,$name,$issue_id), 1, "El issue $issue_id se ha cerrado desde commit")
    }
  }
  my $README =  read_text( "$repo_dir/README.md");
  unlike( $README, qr/[hH]ito/, "El README no debe incluir la palabra hito");

  my $with_pip = grep(/req\w+\.txt/, @repo_files);
  if ($with_pip) {
     ok( grep( /requirements.txt/, @repo_files), "Fichero de requisitos de Python con nombre correcto" );
  }
  if ( $this_hito > 1 ) { # Comprobar milestones y eso
    doing("hito 2");
    isnt( grep( /.travis.yml/, @repo_files), 0, ".travis.yml presente" );
    my $travis_domain = travis_domain( $README, $user, $name );
    ok( $travis_domain =~ /(com|org)/ , "Está presente el badge de Travis con enlace al repo correcto");
    if ( $travis_domain =~ /(com|org)/ ) {
      is( travis_status($README), 'Passing', "Los tests deben pasar en Travis");
    }
  }

  if ( $this_hito > 2 ) { # Despliegue en algún lado
    doing("hito 3");
    my ($deployment_url) = ($README =~ m{(?:[Dd]espliegue|[Dd]eployment)[^\n]+(https://\S+)\b});
    if ( $deployment_url ) {
      diag "☑ Hallado URL de despliegue $deployment_url";
    } else {
      diag "✗ Problemas extrayendo URL de despliegue";
    }
    ok( $deployment_url, "URL de despliegue hito 3");
  SKIP: {
      skip "Ya en el hito siguiente", 2 unless $this_hito == 3;
      my $status = $ua->get($deployment_url);
      if ( ! $status || $status =~ /html/ ) {
	$status = $ua->get( "$deployment_url/status"); # Por si acaso han movido la ruta
      }
      ok( $status->res, "Despliegue hecho en $deployment_url" );
      say "Respuesta ", $status->res;
      like( $status->res->headers->content_type, qr{application/json}, "Status devuelve application/json");
      say "Content Type ", $status->res->headers->content_type;
      my $status_ref = json_from_status( $status );
      like ( $status_ref->{'status'}, qr/[Oo][Kk]/, "Status $status_ref de $deployment_url correcto");
    }
  }

  if ( $this_hito > 3 ) { # Despliegue en algún lado
    doing("hito 4");
    my ($deployment_url) = ($README =~ /(?:[Cc]ontenedor|[Cc]ontainer).+(https:..\S+)\b/);
    unlike($deployment_url, qr{/status}, 'El URL apunta al dominio, no a la ruta status');
    if ( $deployment_url ) {
      diag "☑ Detectado URL de despliegue Docker $deployment_url";
    } else {
      diag "✗ Problemas detectando URL de despliegue de Docker";
    }
    isnt( grep( /Dockerfile/, @repo_files), 0, "Dockerfile presente" );
      
    my ($dockerhub_url) = ($README =~ m{(https://hub.docker.com/r/\S+)\b});
    $dockerhub_url .= "/" if $dockerhub_url !~ m{/$}; # Para evitar redirecciones y errores
    diag "Detectado URL de Docker Hub '$dockerhub_url'";
    ok($dockerhub_url, "Detectado URL de DockerHub");
    if ( ok( $deployment_url,  "URL de despliegue hito 4") ) {
    SKIP: {
	skip "Ya en el hito siguiente", 4 unless $this_hito == 4;
	$deployment_url = ($deployment_url =~ /status/)?$deployment_url:"$deployment_url/status";
	my $status = $ua->get( "$deployment_url" );
	ok( $status->res, "Despliegue hecho en $deployment_url" );
	my $status_ref = json_from_status( $status );
	like ( $status_ref->{'status'}, qr/[Oo][Kk]/, "Status de $deployment_url correcto");
	if ( $dockerhub_url ) {
          my ($dockerfile) = $ua->get("$dockerhub_url/Dockerfile");
	  ok( $dockerfile,  "Dockerfile actualizado en DockerHub");
	}
      }
    }
  }

   if ( $this_hito > 4 ) { # Despliegue en algún lado
    doing("hito 5");
    my ($deployment_url) = ($README =~ /(?:Despliegue final|Final deployment):\s+(\S+)\b/);
    if ( $deployment_url ) {
      diag "☑ Detectada IP de despliegue $deployment_url";
    } else {
      diag "✗ Problemas detectando IP de despliegue";
    }
    unlike( $deployment_url, qr/(heroku|now)/, "Despliegue efectivamente hecho en IaaS" );
    if ( ok( $deployment_url, "URL de despliegue hito 5") ) {
      check_ip($deployment_url);
      my $status = $ua->get("http://$deployment_url/status");
      ok( $status->res, "Despliegue correcto en $deployment_url/status" );
      my $status_ref = json_from_status( $status );
      like ( $status_ref->{'status'}, qr/[Oo][Kk]/, "Status de $deployment_url correcto");
    }
    isnt( grep( /Vagrantfile/, @repo_files), 0, "Vagrantfile presente" );
    isnt( grep( /provision/, @repo_files), 0, "Hay un directorio 'provision'" );
    isnt( grep( m{provision/\w+}, @repo_files), 0, "El directorio 'provision' no está vacío" );
    isnt( grep( /despliegue|deployment/, @repo_files), 0, "Hay un directorio 'despliegue'" );
    isnt( grep( m{(despliegue|deployment)/\w+}, @repo_files), 0, "El directorio 'despliegue' no está vacío" );
  }
};

done_testing();

# Subs -------------------------------------------------------------
# Antes de cada hito
sub doing {
  my $what = shift;
  diag "\n\t✔ Comprobando $what\n";
}


sub how_many_milestones {
  my ($user,$repo) = @_;
  my $page = get_github( "https://github.com/$user/$repo/milestones" );
  my ($milestones ) = ( $page =~ /(\d+)\s+Open/);
  return $milestones;
}

sub closed_issues {
  my ($user,$repo) = @_;
  my $page = get_github( "https://github.com/$user/$repo".'/issues?q=is%3Aissue+is%3Aclosed' );
  my (@closed_issues ) = ( $page =~ m{<a\s+(id=\".+?\")}gs );
  return @closed_issues;

}

sub closes_from_commit {
  my ($user,$repo,$issue) = @_;
  my $page = get_github( "https://github.com/$user/$repo/issues/$issue" );
  return $page =~ /closed\s+this\s+in/gs ;
}

sub check_ip {
  my $ip = shift;
  if ( $ip ) {
    diag "\n\t".check( "Detectada dirección de despliegue $ip" )."\n";
  } else {
    diag "\n\t".fail_x( "Problemas detectando URL de despliegue" )."\n";
  }
  my $pinger = Net::Ping->new();
  $pinger->port_number(22); # Puerto ssh
  isnt($pinger->ping($ip), 0, "$ip es alcanzable");
}

sub check {
  return BOLD.GREEN ."✔ ".RESET.join(" ",@_);
}

sub fail_x {
  return BOLD.MAGENTA."✘".RESET.join(" ",@_);
}

sub get_github {
  my $url = shift;
  my $page = `curl -ss $url`;
  die "No pude descargar la página" if !$page;
  return $page;
}

sub travis_domain {
  my ($README, $user, $name) = @_;
  my ($domain) = ($README =~ /.Build Status..https:\/\/travis-ci.(\w+)\/$user\/$name\.svg.+$name\)/);
  return $domain;
}

sub travis_status {
  my $README = shift;
  my ($build_status) = ($README =~ /Build Status..([^\)]+)\)/);
  my $status_svg = `curl -L -s $build_status`;
  return $status_svg =~ /passing/?"Passing":"Fail";
}

sub objetivos_actualizados {
  my $repo = shift;
  my $objective_file = shift;
  my $date = $repo->command('log', '-1', '--date=relative', '--', "$objective_file");
  my ($hace,$unidad)= $date =~ /Date:.+?(\d+)\s+(\w+)/;
  if ( $unidad =~ /(semana|week|minut)/ ) {
    return 0;
  } elsif ( $unidad =~ /ho/ ) {
    return ($hace > 1 )?1:0;
  } elsif ( $unidad =~ /d\w+/ ){
    return ($hace < 7)?1:0;
  }

}

# Devuelve el JSON del status
sub json_from_status {
  my $status = shift;
  my $body = $status->res->body;
  say "Body → $body";
  return from_json( $body );
}
