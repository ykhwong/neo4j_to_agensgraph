use strict;
use IPC::Open2;
my %unique_import_id;
my $UIL="'UNIQUE +IMPORT +LABEL'";
my $UII="'UNIQUE +IMPORT +ID'";
my ($pid, $out, $in);
my $use_agens=0;

sub proc {
	my $ls = shift;
	return "" if ($ls =~ /^SCHEMA +AWAIT/i);
	return "" if ($ls =~ /^(CREATE|DROP) +CONSTRAINT .+UNIQUE +IMPORT/i);
	return "" if ($ls =~ /^MATCH .+ REMOVE .+/i);

	# Basic change
	$ls =~ s/'/''/g;
	$ls =~ s/\\"([\},])/\\\\'$1/g;
	$ls =~ s/([^\\])(`|")/$1'/g;
	$ls =~ s/\\"/"/g;
	$ls =~ s/^\s*BEGIN\s*$/BEGIN;/i;
	$ls =~ s/^\s*COMMIT\s*$/COMMIT;/i;

	if ($ls =~ /CREATE +\(:'(\S+)':$UIL +\{(.+), $UII:(\d+)\}\);/i) {
		my $vlabel = $1;
		my $keyval = $2;
		my $id = $3;
		$unique_import_id{$id} = $vlabel . "\t" . $keyval;
		$ls =~ s/CREATE +\(:'(\S+)':$UIL +\{/CREATE (:$1 {/i;
		$ls =~ s/, +$UII:\d+\}/\}/i;
	}
	if ($ls =~ /^MATCH +\(n1:$UIL(\{$UII:\d+\})\), +\(n2:$UIL(\{$UII:\d+\})\)/i) {
		my $n1 = $1;
		my $n2 = $2;
		$ls =~ s/$UIL//ig;
		$ls =~ s/\[r:'(\S+)'\]/[r:$1]/i;
		$ls =~ s/\[:'(\S+)'\]/[:$1]/i;
		if ($n1 =~ /(\d+)/) {
			my $id = $unique_import_id{$1};
			$id =~ s/\t/ {/;
			$id .= '}';
			$ls =~ s/$n1/$id/i;
		}
		if ($n2 =~ /(\d+)/) {
			my $id = $unique_import_id{$1};
			$id =~ s/\t/ {/;
			$id .= '}';
			$ls =~ s/$n2/$id/i;
		}
	}
	if ($ls =~ /^CREATE +\(:'(\S+)'/i) {
		$ls =~ s/^CREATE +\(:'(\S+)'/CREATE (:$1/i;
	}
	if ($ls =~ /^CREATE +INDEX +ON +:/i) {
		$ls =~ s/^CREATE +INDEX +ON +:/CREATE PROPERTY INDEX ON /i;
		$ls =~ s/'//g;
	}
	if ($ls =~ /^CREATE +CONSTRAINT +ON +\(\S+:'(\S+)'\) +ASSERT +\S+\.'(\S+)'/i) {
		$ls =~ s/^CREATE +CONSTRAINT +ON +\(\S+:'(\S+)'\) +ASSERT +\S+\.'(\S+)'/CREATE CONSTRAINT ON $1 ASSERT $2/i;
	}
	if ($ls =~ /^MATCH +\(n1:'(\S+)'/i) {
		$ls =~ s/^MATCH +\(n1:'(\S+)'\s*\{/MATCH (n1:$1 {/i;
		$ls =~ s/ +\(n2:'(\S+)'\s*\{/ (n2:$1 {/i;
		$ls =~ s/\[:'(\S+)'\]/[:$1]/i;
	}
	$ls =~ s/\s*$//;
	return $ls;
}

sub load_file {
	my $filename = shift;
	unless ( -f $filename ) {
		print STDERR "File not found: $filename\n";
		exit 1;
	}
	open my $in, '<:raw', $filename or die("Check the file: $filename\n");
	local $/;
	my $contents = <$in>;
	close($in);
	return $contents;
}

sub make_graph_st {
	my $graph_name = shift;
	return "DROP GRAPH IF EXISTS $graph_name CASCADE;\nCREATE GRAPH $graph_name;\nSET GRAPH_PATH=$graph_name;";
}

sub out {
	my $ls = shift;
	my $line;
	return if ($ls =~ /^\s*$/);
	$line = proc($ls);
	return if ($line =~ /^\s*$/);
	if ($use_agens) {
		print $in "$line\n";
		my $msg = <$out>;
		print $msg;
	} else {
		printf("%s\n", $line);
	}
}

sub main {
	my $graph_name;
	my $file;
	my $graph_st;
	my $opt;
	foreach my $arg (@ARGV) {
		if ($arg =~ /^--import-to-agens$/) {
			$use_agens=1;
			next;
		}
		if ($arg =~ /^--graph=(\S+)$/) {
			$graph_name=$1;
			next;
		}
		if ($arg =~ /^(--)(dbname|host|port|username)(=\S+)$/) {
			$opt.=" " . $1 . $2 . $3;
			next;
		}
		if ($arg =~ /^(--)(no-password|password)$/) {
			$opt.=" " . $1 . $2;
			next;
		}
		if ($arg =~ /^--/ || $arg =~ /^--(h|help)$/) {
			printf("USAGE: perl $0 [--import-to-agens] [--graph=GRAPH_NAME] [--help] [filename (optional if STDIN is provided)]\n");
			printf("   Additional optional parameters for the AgensGraph integration:\n");
			printf("      [--dbname=DBNAME] : Database name\n");
			printf("      [--host=HOST]     : Hostname or IP\n");
			printf("      [--port=PORT]     : Port\n");
			printf("      [--username=USER] : Username\n");
			printf("      [--no-password]   : No password\n");
			printf("      [--password]      : Ask password (should happen automatically)\n");
			exit 0;
		}
		$file=$arg;
	}

	if (!$graph_name) {
		printf("Please specify the --graph= parameter to initialize the graph repository.\n");
		exit 1;
	}

	if ($file) {
		if ( ! -f $file ) {
			printf("File not found: %s\n", $file);
			exit 1;
		}
	}
	$graph_st = make_graph_st($graph_name);
	if ($use_agens) {
		`agens --help`;
		if ($? ne 0) {
			printf("agens client is not available.\n");
			exit 1;
		}
		$pid = open2 $out, $in, "agens $opt";
		die "$0: open2: $!" unless defined $pid;
		print $in $graph_st . "\n";
		my $msg = <$out>;
		print $msg;
	} else {
		printf("%s\n", $graph_st);
	}
	if ($file) {
		foreach my $ls (split /\n/, load_file($file)) {
			out($ls);
		}
	} else {
		while (<STDIN>) {
			out($_);
		}
	}
	if ($use_agens) {
		close $in or warn "$0: close: $!";  
		close $out or warn "$0: close: $!";
	}
}

main();

