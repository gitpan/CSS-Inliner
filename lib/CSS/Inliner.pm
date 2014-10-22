# $Id: Inliner.pm 2897 2010-10-29 23:00:42Z kamelkev $
#
# Copyright 2009 MailerMailer, LLC - http://www.mailermailer.com
#
# Based loosely on the TamTam RubyForge project:
# http://tamtam.rubyforge.org/

package CSS::Inliner;

use strict;
use warnings;

use vars qw($VERSION);
$VERSION = sprintf "%d", q$Revision: 2897 $ =~ /(\d+)/;

use Carp;

use HTML::TreeBuilder;
use CSS::Simple;
use HTML::Query 'query';
use LWP::UserAgent;
use URI;

=pod

=head1 NAME

CSS::Inliner - Library for converting CSS <style> blocks to inline styles.

=head1 SYNOPSIS

use Inliner;

my $inliner = new Inliner();

$inliner->read_file({filename => 'myfile.html'});

print $inliner->inlinify();

=head1 DESCRIPTION

Library for converting CSS style blocks into inline styles in an HTML
document.  Specifically this is intended for the ease of generating
HTML emails.  This is useful as even in 2009 Gmail and Hotmail don't
support top level <style> declarations.

=head1 CONSTRUCTOR

=over 4

=item new ([ OPTIONS ])

Instantiates the Inliner object. Sets up class variables that are used
during file parsing/processing. Possible options are:

B<html_tree> (optional). Pass in a custom instance of HTML::Treebuilder

B<strip_attrs> (optional). Remove all "id" and "class" attributes during inlining

B<leave_style> (optional). Leave style/link tags alone within <head> during inlining

=back
=cut

sub new {
  my ($proto, $params) = @_;

  my $class = ref($proto) || $proto;

  my $self = {
    stylesheet => undef,
    css => CSS::Simple->new(),
    html => undef,
    html_tree => $$params{html_tree} || HTML::TreeBuilder->new(),
    query => HTML::Query->new(),
    strip_attrs => defined($$params{strip_attrs}) ? 1 : 0,
    leave_style => defined($$params{leave_style}) ? 1 : 0,
  };

  bless $self, $class;
  return $self;
}

=head1 METHODS

=cut

=pod

=over 5

=item fetch_file( params )

Fetches a remote HTML file that supposedly contains both HTML and a
style declaration. It subsequently calls the read() method
automatically.

This method expands all relative urls, as well as fully expands the 
stylesheet reference within the document.

This method requires you to pass in a params hash that contains a
url argument for the requested document. For example:

$self->fetch_file({ url => 'http://www.example.com' });

=cut

sub fetch_file {
  my ($self,$params) = @_;

  unless ($params && $$params{url}) {
    croak "You must pass in hash params that contain a url argument";
  }

  #fetch a absolutized version of the html
  my $html = $self->_fetch_html({ url => $$params{url}});

  $self->read({html => $html});

  return();
}

=item read_file( params )

Opens and reads an HTML file that supposedly contains both HTML and a
style declaration.  It subsequently calls the read() method
automatically.

This method requires you to pass in a params hash that contains a
filename argument. For example:

$self->read_file({filename => 'myfile.html'});

=cut

sub read_file {
  my ($self,$params) = @_;

  unless ($params && $$params{filename}) {
    croak "You must pass in hash params that contain a filename argument";
  }

  open FILE, "<", $$params{filename} or die $!;
  my $html = do { local( $/ ) ; <FILE> } ;

  $self->read({html => $html});

  return();
}

=pod

=item read( params )

Reads html data and parses it.  The intermediate data is stored in
class variables.

The <style> block is ripped out of the html here, and stored
separately. Class/ID/Names used in the markup are left alone.

This method requires you to pass in a params hash that contains scalar
html data. For example:

$self->read({html => $html});

=cut

sub read {
  my ($self,$params) = @_;

  unless ($params && $$params{html}) {
    croak "You must pass in hash params that contains html data";
  }

  $self->_get_tree()->store_comments(1);
  $self->_get_tree()->parse($$params{html});

  $self->_get_query({tree => $self->_get_tree()});

  #suck in the styles for later use from the head section - stylesheets anywhere else are invalid
  my $stylesheet = $self->_parse_stylesheet();

  #save the data
  $self->_set_html({ html => $$params{html} });
  $self->_set_stylesheet({ stylesheet => $stylesheet});

  return();
}

=pod

=item inlinify()

Processes the html data that was entered through either 'read' or
'read_file', returns a scalar that contains a composite chunk of html
that has inline styles instead of a top level <style> declaration.

=back

=cut

sub inlinify {
  my ($self,$params) = @_;

  unless ($self && ref $self) {
    croak "You must instantiate this class in order to properly use it";
  }

  unless ($self->{html} && defined $self->_get_tree()) {
    croak "You must instantiate and read in your content before inlinifying";
  }

  my $html;
  if (defined $self->_get_css()) {
    #parse and store the stylesheet as a hash object

    $self->_get_css()->read({css => $self->{stylesheet}});

    my %matched_elements;
    my $count = 0;

    foreach my $key ($self->_get_css()->get_selectors()) {

      #skip over psuedo selectors, they are not mappable the same
      next if $key =~ /\w:(?:active|focus|hover|link|visited|after|before|selection|target|first-line|first-letter)\b/io;

      #skip over @import or anything else that might start with @ - not inlineable
      next if $key =~ /^\@/io;

      my $query_result = $self->query({ selector => $key });

      # CSS rules cascade based on the specificity and order
      my $specificity = $self->specificity({selector => $key});

      #if an element matched a style within the document store the rule, the specificity
      #and the actually CSS attributes so we can inline it later
      foreach my $element (@{$query_result->get_elements()}) {

       $matched_elements{$element->address()} ||= [];
        my %match_info = (
          rule     => $key,
          element  => $element,
          specificity   => $specificity,
          position => $count,
          css      => $self->_get_css()->get_properties({selector => $key}),
         );
  
        push(@{$matched_elements{$element->address()}}, \%match_info);
        $count++;
      }
    }

    #process all elements
    foreach my $matches (values %matched_elements) {
      my $element = $matches->[0]->{element};
      # rules are sorted by specificity, and if there's a tie the position is used
      # we sort with the lightest items first so that heavier items can override later
      my @sorted_matches = sort { $a->{specificity} <=> $b->{specificity} || $a->{position} <=> $b->{position} } @$matches;

      my %new_style;
      foreach my $match (@sorted_matches) {
        %new_style = (%new_style, %{$match->{css}});
      }

      # styles already inlined have greater precedence
      if (defined($element->attr('style'))) {
        my $cur_style = $self->_split({style => $element->attr('style')});
        %new_style = (%new_style, %{$cur_style});
      }

      $element->attr('style', $self->_expand({properties => \%new_style}));
    }

    #at this point we have a document that contains the expanded inlined stylesheet
    #BUT we need to collapse the properties to remove duplicate overridden styles
    $self->_collapse_inline_styles();

    # The entities list is the do-not-encode string from HTML::Entities
    # with the single quote added.

    # 3rd argument overrides the optional end tag, which for HTML::Element
    # is just p, li, dt, dd - tags we want terminated for our purposes

    $html = $self->_get_tree()->as_HTML(q@^\n\r\t !\#\$%\(-;=?-~'@,' ',{});
  }
  else {
    $html = $self->{html};
  }

  return $html;
}

=pod

=item query()

Given a particular selector return back the applicable styles

=back

=cut

sub query {
  my ($self,$params) = @_;

  return $self->_get_query()->query($$params{selector});
}

=pod

=item specificity()

Given a particular selector return back the associated selectivity

=back

=cut

sub specificity {
  my ($self,$params) = @_;

  return $self->_get_query()->get_specificity($$params{selector});
}

####################################################################
#                                                                  #
# The following are all private methods and are not for normal use #
# I am working to finalize the get/set methods to make them public #
#                                                                  #
####################################################################

sub _fetch_url {
  my ($self,$params) = @_;

  # Create a user agent object
  my $ua = LWP::UserAgent->new;
  $ua->agent("CSS::Inliner" . $ua->agent);
  $ua->protocols_allowed( ['http','https'] );

  # Create a request     
  my $uri = URI->new($$params{url});

  my $req = HTTP::Request->new('GET',$uri);

  # Pass request to the user agent and get a response back
  my $res = $ua->request($req);

  # if not successful
  if (!$res->is_success()) {
    die 'There was an error in fetching the document for '.$uri.' : '.$res->message;
  }

  # Is it a HTML document
  if ($res->content_type ne 'text/html' && $res->content_type ne 'text/css') {
    die 'The web site address you entered is not an HTML document.';
  }

  # remove the <HTML> tag pair as parser will add it again.
  my $content = $res->content || ''; 
  $content =~ s|</?html>||gi;

  # Expand all URLs to absolute ones
  my $baseref = $res->base;

  return ($content,$baseref);
}

sub _fetch_html {
  my ($self,$params) = @_;

  my ($content,$baseref) = $self->_fetch_url({ url => $$params{url} });

  # Build the HTML tree
  my $doc = HTML::TreeBuilder->new();
  $doc->parse($content);
  $doc->eof;

  # Change relative links to absolute links
  $self->_changelink_relative({ content => $doc->content, baseref => $baseref});

  $self->_expand_stylesheet({ content => $doc, html_baseref => $baseref });

  return $doc->as_HTML(q@^\n\r\t !\#\$%\(-;=?-~'@,' ',{});
}

sub _changelink_relative {
  my ($self,$params) = @_;

  my $base = $$params{baseref};
  
  foreach my $i (@{$$params{content}}) {
  
    next unless ref $i eq 'HTML::Element';
  
    if ($i->tag eq 'img' or $i->tag eq 'frame' or $i->tag eq 'input' or $i->tag eq 'script') {
  
      if ($i->attr('src') and $base) {
        # Construct a uri object for the attribute 'src' value
        my $uri = URI->new($i->attr('src'));
        $i->attr('src',$uri->abs($base));
      }                         # end 'src' attribute
    }
    elsif ($i->tag eq 'form' and $base) {
      # Construct a new uri for the 'action' attribute value
      my $uri = URI->new($i->attr('action'));
      $i->attr('action', $uri->abs($base));
    }
    elsif (($i->tag eq 'a' or $i->tag eq 'area' or $i->tag eq 'link') and $i->attr('href') and $i->attr('href') !~ /^\#/) {
      # Construct a new uri for the 'href' attribute value
      my $uri = URI->new($i->attr('href'));

      # Expand URLs to absolute ones if base uri is defined.
      my $newuri = $base ? $uri->abs($base) : $uri;

      $i->attr('href', $newuri->as_string());
    }
    elsif ($i->tag eq 'td' and $i->attr('background') and $base) {
      # adjust 'td' background
      my $uri = URI->new($i->attr('background'));
      $i->attr('background',$uri->abs($base));
    }                           # end tag choices

    # Recurse down tree
    if (defined $i->content) {
      $self->_changelink_relative({ content => $i->content, baseref => $base });
    }
  }
}

sub __fix_relative_url {
  my ($self,$params) = @_;

  my $uri = URI->new($$params{url});
  
  return $$params{prefix} . "'" . $uri->abs($$params{base})->as_string ."'";
}

sub _expand_stylesheet {
  my ($self,$params) = @_;

  my $doc = $$params{content};

  my $stylesheets = ();

  my $head = $doc->look_down("_tag", "head"); # there should only be one

  #get the external <style> nodes underneath the head section - that's the only place stylesheets are allowed to live
  my @style = $head->look_down('_tag','style','href',qr/^https?:\/\//);

  #get the <link> nodes underneath the head section - that's the only place stylesheets are allowed to live
  my @link = $head->look_down('_tag','link','rel','stylesheet');

  my @stylesheets = (@style,@link);

  foreach my $i (@link) {
    my ($content,$baseref) = $self->_fetch_url({ url => $i->attr('href') });

    #absolutized the assetts within the stylesheet that are relative 
    $content =~ s/(url\()["']?((?:(?!https?:\/\/)(?!\))[^"'])*)["']?(?=\))/$self->__fix_relative_url({prefix => $1, url => $2, base => $baseref})/exsgi;

    my $stylesheet = HTML::Element->new('style', type => "text/css", rel=> "stylesheet");
    $stylesheet->push_content($content);

    $i->replace_with($stylesheet);
  }

  foreach my $i (@style) {
    #use the baseref from the original document fetch
    my $baseref = $$params{html_baseref};
  
    my $content = $i->content();

    #absolutized the assetts within the stylesheet that are relative 
    $content =~ s/(url\()["']?((?:(?!https?:\/\/)(?!\))[^"'])*)["']?(?=\))/$self->__fix_relative_url({prefix => $1, url => $2, base => $baseref})/exsgi;

    my $stylesheet = HTML::Element->new('style');
    $stylesheet->push_content($content);

    $i->replace_with($stylesheet);
  }

  return();
}

sub _parse_stylesheet {
  my ($self,$params) = @_;

  my $stylesheet = '';

  #get the head section of the document
  my $head = $self->_get_tree()->look_down("_tag", "head"); # there should only be one

  #get the <style> nodes underneath the head section - that's the only place stylesheets are allowed to live
  my @style = $head->look_down('_tag','style','type','text/css');
 
  #get the <link> nodes underneath the head section - there should be *none* at this step in the process
  my @link = $head->look_down('_tag','link','rel','stylesheet','type','text/css');

  if (scalar @link) {
    die 'Inliner only supports link tags if you fetch the document from a remote source';
  }

  foreach my $i (@style) {

    #process this node if the html media type is screen, all or undefined (which defaults to screen)
    if (($i->tag eq 'style') && (!$i->attr('media') || $i->attr('media') =~ m/\b(all|screen)\b/)) {

      foreach my $item ($i->content_list()) {
        # remove HTML comment markers
        $item =~ s/<!--//mg;
        $item =~ s/-->//mg;

        $stylesheet .= $item;
      }
    }

    unless ($self->_leave_style()) {
      $i->delete();
    }
  }

  return $stylesheet;
}

sub _collapse_inline_styles {
  my ($self,$params) = @_;

  #check if we were passed a node to recurse from, otherwise use the root of the tree
  my $content = exists($$params{content}) ? $$params{content} : [$self->_get_tree()];

  foreach my $i (@{$content}) {

    next unless (ref $i eq 'HTML::Element' || ref $i eq 'HTML::TreeBuilder');

    if ($i->attr('style')) {

      # hold the property value pairs
      my $styles = $self->_split({style => $i->attr('style')});

      my $collapsed_style = '';
      foreach my $key (sort keys %{$styles}) { #sort for predictable output
        $collapsed_style .= $key . ': ' . $$styles{$key} . '; ';
      }

      $collapsed_style =~ s/\s*$//;
      $i->attr('style', $collapsed_style); 
    }

    #if we have specifically asked to remove the inlined attrs, remove them
    if ($self->_strip_attrs()) {
      $i->attr('id',undef);
      $i->attr('class',undef);
    }

    # Recurse down tree
    if (defined $i->content) {
      $self->_collapse_inline_styles({content => $i->content()});
    }
  }
}

sub _get_tree {
  my ($self,$params) = @_;

  return $self->{html_tree};
}

sub _get_query {
  my ($self,$params) = @_;

  if (exists $$params{tree}) {
    $self->{query} = HTML::Query->new($self->_get_tree());
  }

  return $self->{query};
}

sub _get_css {
  my ($self,$params) = @_;

  return $self->{css};
}

sub _strip_attrs {
  my ($self,$params) = @_;

  return $self->{strip_attrs};
}

sub _leave_style {
  my ($self,$params) = @_;

  return $self->{leave_style};
}

sub _set_html {
  my ($self,$params) = @_;

  $self->{html} = $$params{html};

  return $self->{html};
}

sub _set_stylesheet {
  my ($self,$params) = @_;

  $self->{stylesheet} = $$params{stylesheet};

  return $self->{stylesheet};
}

sub _expand {
  my ($self, $params) = @_;

  my $properties = $$params{properties};
  my $inline = '';
  foreach my $key (keys %{$properties}) {
    $inline .= $key . ':' . $$properties{$key} . ';';
  }

  return $inline;
}

sub _split {
  my ($self, $params) = @_;
  my $style = $params->{style};
  my %split;

  # Split into properties
  foreach ( grep { /\S/ } split /\;/, $style ) {
    unless ( /^\s*([\w._-]+)\s*:\s*(.*?)\s*$/ ) {
      croak "Invalid or unexpected property '$_' in style '$style'";
    }
    $split{lc $1} = $2;
  }

  return \%split;
}

1;

=pod

=head1 Sponsor

This code has been developed under sponsorship of MailerMailer LLC, http://www.mailermailer.com/

=head1 AUTHOR

Kevin Kamel <C<kamelkev@mailermailer.com>>

=head1 CONTRIBUTORS

Vivek Khera <C<vivek@khera.org>>
Michael Peters <C<wonko@cpan.org>>

=head1 LICENSE

This module is Copyright 2010 Khera Communications, Inc.  It is
licensed under the same terms as Perl itself.

=cut
