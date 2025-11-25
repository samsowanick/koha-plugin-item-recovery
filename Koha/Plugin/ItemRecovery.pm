package Koha::Plugin::ItemRecovery;
# David Bourgault, 2017 - Inlibro
# Modified by Samuel Sowanick, 2025 - Corvallis Benton County Public Library
#
# This plugin allows you to undelete records and their items that you have deleted by mistake. With special empahsis on recoverying Fast Add materials
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
use Modern::Perl;
use strict;
use warnings;
use CGI;
use utf8;
use DBI;
use base qw(Koha::Plugins::Base);
use C4::Auth;
use C4::Context;
use Koha::DateUtils qw( dt_from_string );
use Data::Dumper;
use Koha::SearchEngine::Elasticsearch::Indexer;
use Koha::SearchEngine::Zebra::Indexer;
use Koha::SearchEngine;
use Koha::Biblios;
use Koha::Biblio;
use Try::Tiny;


our $VERSION = '1.3';
our $metadata = {
    name            => 'Item Recovery',
    author          => 'Samuel Sowanick',
    description     => 'This tool allows staff to search for and recover deleted items by barcode. This can help with the quick recovery of fast adds.',
    date_authored   => '2025-10-11',
    date_updated    => '2025-10-18',
    minimum_version => '22.05',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};
    my $template = $self->get_template({ file => 'home.tt' });

    my $action = $cgi->param('action') || '';
    my $confirm = $cgi->param('confirm') || '';
    
    
    $template->param(
        BarcodeList          => $cgi->param('BarcodeList') || '', 
        target               => $cgi->param('target') || undef,
        success_message      => $cgi->param('success_message') || undef, 
        error_message        => $cgi->param('error_message') || undef,   
        all_itemnumbers      => [],
        all_barcodes         => [],
        all_titles           => [],
        all_authors          => [],
        all_isbn             => [],
        all_issn             => [],
        all_biblionumbers    => [],
        all_timestamps       => [],
        all_issimilarbarcode => [],
    );


    if ( $action eq 'calculate' ) {
        my $target      = $cgi->param('target');
        my $barcode_list = $cgi->param('BarcodeList');
        
        try {
            $self->calculate( $template, $target, $barcode_list, $cgi );
        } catch {
            $template->param(
                error_message => "A fatal script error occurred during the search. The error details are: $_"
            );
        };
    }
	
elsif ( $action eq 'merge' and $confirm eq 'confirm' ) {
    my $target = $cgi->param('target');
    
    my @selected_itemnumbers;
    
    @selected_itemnumbers = $cgi->multi_param('selected_itemnumbers');
    
    if (!@selected_itemnumbers) {
        @selected_itemnumbers = $cgi->param('selected_itemnumbers[]');
        if (ref($selected_itemnumbers[0]) eq 'ARRAY') {
            @selected_itemnumbers = @{$selected_itemnumbers[0]};
        }
    }
    
    if (!@selected_itemnumbers) {
        my %vars = $cgi->Vars();
        if (defined $vars{'selected_itemnumbers[]'}) {
            my $val = $vars{'selected_itemnumbers[]'};
            if (ref($val) eq 'ARRAY') {
                @selected_itemnumbers = @$val;
            } else {
                @selected_itemnumbers = split(/\0/, $val);
            }
        }
    }
    # Debugging
    my $debug_info = "Attempted to capture checkboxes. Found: " . scalar(@selected_itemnumbers) . " items";
    $debug_info .= " (values: " . join(', ', @selected_itemnumbers) . ")" if @selected_itemnumbers;
    
    warn "DEBUG MERGE: $debug_info";
    
    my $barcode_list = $cgi->param('BarcodeList') || '';
    $template->param(
        BarcodeList => $barcode_list,
        target      => $target,
        error_message => $debug_info,  
    );
    
    $self->fusion( $template, \@selected_itemnumbers, $cgi );
}
    else {
        
    }

    print $cgi->header( -type => 'text/html', -charset => 'utf-8' );
    print $template->output();
}

sub calculate {
    my ( $self, $template, $target, $barcode_list, $cgi ) = @_;
    
    my $dbh = C4::Context->dbh;

    $template->param(
        BarcodeList => $barcode_list,
        target      => $target,
    );
    
    my @barcodes = grep { /\S/ } split( /[\r\n]+/, $barcode_list // '' );
    for (@barcodes) {
        s/^\s+|\s+$//g;
    }
    
    unless (@barcodes) {
        $template->param(
            target => $target,
            error_message => 'Please enter at least one barcode.'
        );
        return;
    }

    if (scalar @barcodes > 100) {
        @barcodes = @barcodes[0..99]; # Keep the first 100
        $template->param(
            error_message => "Only the first 100 barcodes were processed to prevent system overload."
        );
    }

    my $placeholders = join ',', ('?') x @barcodes;

    my $all_deleted_sql = "
        SELECT di.itemnumber, di.barcode,
               COALESCE(db.title, b.title) AS title,
               COALESCE(db.author, b.author) AS author,
               COALESCE(dbi.isbn, bi.isbn) AS isbn,
               COALESCE(dbi.issn, bi.issn) AS issn,
               di.biblionumber, di.timestamp,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.barcode = di.barcode)
                    THEN '*'
                    ELSE ''
               END AS is_duplicate
        FROM deleteditems di
        LEFT JOIN deletedbiblioitems dbi ON di.biblionumber = dbi.biblionumber
        LEFT JOIN deletedbiblio db ON di.biblionumber = db.biblionumber
        LEFT JOIN biblio b ON di.biblionumber = b.biblionumber
        LEFT JOIN biblioitems bi ON di.biblionumber = bi.biblionumber
        WHERE di.barcode IN ($placeholders)
    ";

    my @results;
    
    try {
        my $sth = $dbh->prepare($all_deleted_sql) or die $dbh->errstr;
        $sth->execute(@barcodes) or die $dbh->errstr;
    
        while ( my $row = $sth->fetchrow_hashref ) {
            push @results, $row;
        }
    
    } catch {
        $template->param(
            error_message => "A database error occurred while searching. Error: $_"
        );
        warn "SQL EXECUTION ERROR in calculate for barcodes: " . join(', ', @barcodes) . ". Error: $_";
        return;
    };
    
    # --- Process the results for the template ---
    my @all_itemnumbers;
    my @all_barcodes;
    my @all_titles;
    my @all_authors;
    my @all_isbn;
    my @all_issn;
    my @all_biblionumbers;
    my @all_timestamps;
    my @all_issimilarbarcode;

    foreach my $row (@results) {
        push @all_itemnumbers, $row->{itemnumber};
        push @all_barcodes, $row->{barcode};
        push @all_titles, $row->{title};
        push @all_authors, $row->{author};
        push @all_isbn, $row->{isbn};
        push @all_issn, $row->{issn};
        push @all_biblionumbers, $row->{biblionumber};
        push @all_timestamps, $row->{timestamp};
        push @all_issimilarbarcode, $row->{is_duplicate}; 
    }
    
    $template->param(
        target               => $target,
        all_itemnumbers      => \@all_itemnumbers,
        all_barcodes         => \@all_barcodes,
        all_titles           => \@all_titles,
        all_authors          => \@all_authors,
        all_isbn             => \@all_isbn,
        all_issn             => \@all_issn,
        all_biblionumbers    => \@all_biblionumbers,
        all_timestamps       => \@all_timestamps,
        all_issimilarbarcode => \@all_issimilarbarcode,
    );
}


sub fusion {
    my ( $self, $template, $selected_itemnumbers_ref, $cgi ) = @_;
    my @selected_itemnumbers = @$selected_itemnumbers_ref;
    
    $template->param(
        success_message => undef,
        error_message => undef,
        selected_biblionumbers => [],
        selected_count => [],
    );

    unless (@selected_itemnumbers) {
        $template->param(
            error_message => "No items were selected for recovery."
        );
        return;
    }

    my $dbh = C4::Context->dbh;
    my $item_placeholders = join ',', ('?') x @selected_itemnumbers;
    
    my @recovered_itemnumbers = @selected_itemnumbers;

    my @selected_biblionumbers;
    my $bib_sth = $dbh->prepare("SELECT DISTINCT biblionumber FROM deleteditems WHERE itemnumber IN ($item_placeholders)");
    $bib_sth->execute(@selected_itemnumbers);
    while ( my ($biblionumber) = $bib_sth->fetchrow_array ) {
        push @selected_biblionumbers, $biblionumber;
    }
    
    unless (@selected_biblionumbers) {
        $template->param(
            error_message => "Could not find any biblio records associated with the selected deleted items in the deleted records tables."
        );
        return;
    }

    my $bib_placeholders = join ',', ('?') x @selected_biblionumbers;


	$dbh->begin_work;
    try {
        
        # Restore biblio records
try {
    my $rows = $dbh->do("
        INSERT IGNORE INTO biblio (biblionumber,frameworkcode,author,title,medium,subtitle,part_number,part_name,unititle,notes,serial,seriestitle,copyrightdate,timestamp,datecreated,abstract)
        SELECT biblionumber,COALESCE(frameworkcode,''),author,title,medium,subtitle,part_number,part_name,unititle,notes,serial,seriestitle,NULLIF(copyrightdate, '') AS copyrightdate,NULLIF(timestamp, '') AS timestamp,NULLIF(datecreated, '') AS datecreated,abstract 
        FROM deletedbiblio db
        WHERE db.biblionumber IN ($bib_placeholders)
    ", undef, @selected_biblionumbers);
    warn "BIBLIO: Attempted to insert " . scalar(@selected_biblionumbers) . " records, actually inserted: " . ($rows || 0);
} catch {
    die "BIBLIO INSERT FAILED: $_";
};

# Restore biblioitems records
try {
    my $rows = $dbh->do("
        INSERT IGNORE INTO biblioitems (biblioitemnumber,biblionumber,volume,number,itemtype,isbn,issn,ean,publicationyear,publishercode,volumedate,volumedesc,collectiontitle,collectionissn,collectionvolume,editionstatement,editionresponsibility,timestamp,illus,pages,notes,size,place,lccn,url,cn_source,cn_class,cn_item,cn_suffix,cn_sort,agerestriction,totalissues)
        SELECT biblioitemnumber,biblionumber,volume,number,itemtype,isbn,issn,ean,publicationyear,publishercode,volumedate,volumedesc,collectiontitle,collectionissn,collectionvolume,editionstatement,editionresponsibility,NULLIF(timestamp, '') AS timestamp,illus,pages,notes,size,place,lccn,url,cn_source,cn_class,cn_item,cn_suffix,cn_sort,agerestriction,totalissues 
        FROM deletedbiblioitems dbi
        WHERE dbi.biblionumber IN ($bib_placeholders)
    ", undef, @selected_biblionumbers);
    warn "BIBLIOITEMS: Attempted to insert " . scalar(@selected_biblionumbers) . " records, actually inserted: " . ($rows || 0);
} catch {
    die "BIBLIOITEMS INSERT FAILED: $_";
};

# Restore metadata records - DON'T restore the ID, let MySQL generate it
try {
    my $rows = $dbh->do("
        INSERT INTO biblio_metadata (biblionumber, format, `schema`, metadata, timestamp)
        SELECT biblionumber, format, `schema`, metadata, NULLIF(timestamp, '') AS timestamp
        FROM deletedbiblio_metadata dbm
        WHERE dbm.biblionumber IN ($bib_placeholders)
        AND NOT EXISTS (
            SELECT 1 FROM biblio_metadata bm 
            WHERE bm.biblionumber = dbm.biblionumber
        )
    ", undef, @selected_biblionumbers);
    warn "BIBLIO_METADATA: Attempted to insert " . scalar(@selected_biblionumbers) . " records, actually inserted: " . ($rows || 0);
} catch {
    die "BIBLIO_METADATA INSERT FAILED: $_";
};
        
        # Check for and rename duplicate barcodes before restoring items
        try {
            $dbh->do("
                UPDATE deleteditems di
                SET barcode = CONCAT(di.barcode, '_rec')
                WHERE di.itemnumber IN ($item_placeholders)
                AND EXISTS (SELECT 1 FROM items i WHERE i.barcode = di.barcode)
            ", undef, @selected_itemnumbers);
        } catch {
            die "DUPLICATE BARCODE UPDATE FAILED: $_";
        };

		$dbh->do("
		UPDATE deleteditems di
		SET holdingbranch = (SELECT branchcode FROM branches LIMIT 1),
		homebranch = (SELECT branchcode FROM branches LIMIT 1)
		WHERE di.itemnumber IN ($item_placeholders)
		AND (holdingbranch NOT IN (SELECT branchcode FROM branches)
			OR homebranch NOT IN (SELECT branchcode FROM branches))
		", undef, @selected_itemnumbers);

        # Restore items
try {
            $dbh->do("
                INSERT INTO items (itemnumber,biblionumber,biblioitemnumber,barcode,bookable,dateaccessioned,booksellerid,homebranch,price,replacementprice,replacementpricedate,datelastborrowed,datelastseen,stack,notforloan,damaged,damaged_on,itemlost,itemlost_on,withdrawn,withdrawn_on,itemcallnumber,coded_location_qualifier,issues,renewals,localuse,reserves,restricted,itemnotes,itemnotes_nonpublic,holdingbranch,timestamp,deleted_on,location,permanent_location,onloan,cn_source,cn_sort,ccode,materials,uri,itype,more_subfields_xml,enumchron,copynumber,stocknumber,new_status,exclude_from_local_holds_priority)
                SELECT itemnumber,biblionumber,biblioitemnumber,barcode,bookable,NULLIF(dateaccessioned, '') AS dateaccessioned,booksellerid,homebranch,price,replacementprice,NULLIF(replacementpricedate, '') AS replacementpricedate,NULLIF(datelastborrowed, '') AS datelastborrowed,NULLIF(datelastseen, '') AS datelastseen,stack,notforloan,damaged,NULLIF(damaged_on, '') AS damaged_on**,itemlost,NULLIF(itemlost_on, '') AS itemlost_on,withdrawn,NULLIF(withdrawn_on, '') AS withdrawn_on**,itemcallnumber,coded_location_qualifier,issues,renewals,localuse,reserves,restricted,itemnotes,itemnotes_nonpublic,holdingbranch,NULLIF(timestamp, '') AS timestamp,deleted_on,location,permanent_location,onloan,cn_source,cn_sort,ccode,materials,uri,itype,more_subfields_xml,enumchron,copynumber,stocknumber,new_status,exclude_from_local_holds_priority
                FROM deleteditems
                WHERE itemnumber IN ($item_placeholders)
            ", undef, @selected_itemnumbers);
        } catch {
            die "ITEMS INSERT FAILED: $_";
        };

		# Clean up deleted items FIRST
        try {
            $dbh->do("DELETE FROM deleteditems WHERE itemnumber IN ($item_placeholders)", undef, @selected_itemnumbers);
        } catch {
            die "DELETEDITEMS CLEANUP FAILED: $_";
        };

        # Clean up deleted tables
			try {
		$dbh->do("
			DELETE FROM deletedbiblio_metadata 
			WHERE biblionumber IN ($bib_placeholders)
			AND NOT EXISTS (
				SELECT 1 FROM deleteditems di 
				WHERE di.biblionumber = deletedbiblio_metadata.biblionumber
			)
		", undef, @selected_biblionumbers);
    
		$dbh->do("
			DELETE FROM deletedbiblioitems 
			WHERE biblionumber IN ($bib_placeholders)
			AND NOT EXISTS (
				SELECT 1 FROM deleteditems di 
				WHERE di.biblionumber = deletedbiblioitems.biblionumber
			)
		", undef, @selected_biblionumbers);
    
		$dbh->do("
			DELETE FROM deletedbiblio 
			WHERE biblionumber IN ($bib_placeholders)
			AND NOT EXISTS (
				SELECT 1 FROM deleteditems di 
				WHERE di.biblionumber = deletedbiblio.biblionumber
			)
		", undef, @selected_biblionumbers);
		} catch {
		    die "DELETED TABLES CLEANUP FAILED: $_";
		};
        
        $dbh->commit; # Finalize changes if all queries succeeded

    } catch {
        warn "Item recovery failed: $_";
        $dbh->rollback;
        $template->param(
            error_message => "A database error occurred during item recovery. No changes were made. Error: $_"
        );
    };

	# After successful commit, before reindex
	my $recovered_count = scalar(@selected_itemnumbers);
	my $biblios_cleaned = $dbh->selectrow_array("
		SELECT COUNT(*) FROM biblio 
		WHERE biblionumber IN ($bib_placeholders)
	", undef, @selected_biblionumbers);

	$template->param(
		success_message => "Successfully recovered $recovered_count item(s) across $biblios_cleaned bibliographic record(s)."
	);

    # Re-index the affected records
    $self->reindex_biblios(\@selected_biblionumbers);
}

sub reindex_biblios {
    my ($self, $biblio_ids_ref) = @_;
    my @biblio_ids = @$biblio_ids_ref;

    return unless @biblio_ids;

    my $search_engine = C4::Context->preference("SearchEngine");
    
    warn "Starting reindex of " . scalar(@biblio_ids) . " biblios with search engine: $search_engine";

    if ($search_engine eq 'Elasticsearch') {
        $self->reindex_elasticsearch(\@biblio_ids);
    }
    elsif ($search_engine eq 'Zebra') {
        $self->reindex_zebra(\@biblio_ids);
    }
    else {
        warn "Unknown search engine: $search_engine. Unable to reindex.";
    }
}

sub reindex_elasticsearch {
    my ($self, $biblio_ids_ref) = @_;
    my @biblio_ids = @$biblio_ids_ref;
    
    require Koha::SearchEngine::Elasticsearch::Indexer;
    
    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ 
        index => $Koha::SearchEngine::BIBLIOS_INDEX 
    });
    
    my @records_to_index;
    my @valid_biblio_ids;
    
    foreach my $biblionumber (@biblio_ids) {
        my $biblio = Koha::Biblios->find($biblionumber);
        unless ($biblio) {
            warn "Could not find biblio $biblionumber for reindexing";
            next;
        }
        
        # Get the MARC record with embedded item data
        my $marc_record = eval { $biblio->metadata->record };
        unless ($marc_record) {
            warn "Could not get MARC record for biblio $biblionumber: $@";
            next;
        }
        
        # Embed item data into the MARC record
        my @items = $biblio->items->as_list;
        foreach my $item (@items) {
            try {
                my $item_field = $item->as_marc_field;
                $marc_record->append_fields($item_field) if $item_field;
            } catch {
                warn "Could not add item " . $item->itemnumber . " to MARC for biblio $biblionumber: $_";
            };
        }
        
        push @records_to_index, $marc_record;
        push @valid_biblio_ids, $biblionumber;
        
        warn "Prepared biblio $biblionumber for Elasticsearch indexing with " . scalar(@items) . " items";
    }
    
    if (@records_to_index) {
        try {
            $indexer->update_index(\@valid_biblio_ids, \@records_to_index);
            warn "Successfully indexed " . scalar(@valid_biblio_ids) . " records in Elasticsearch";
        } catch {
            warn "Elasticsearch indexing failed: $_";
        };
    } else {
        warn "No valid records to index in Elasticsearch";
    }
}

sub reindex_zebra {
    my ($self, $biblio_ids_ref) = @_;
    my @biblio_ids = @$biblio_ids_ref;
    
    require C4::Biblio;
    
    foreach my $biblionumber (@biblio_ids) {
        try {
            # ModZebra automatically includes all item data
            C4::Biblio::ModZebra($biblionumber, "specialUpdate", "biblioserver");
            warn "Successfully queued biblio $biblionumber for Zebra reindexing";
        } catch {
            warn "Failed to reindex biblio $biblionumber in Zebra: $_";
        };
    }
    
    warn "Queued " . scalar(@biblio_ids) . " records for Zebra indexing";
}


sub uninstall {
    my ( $self, $args ) = @_;
    
    return 1;
}

1;
