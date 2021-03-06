package Text::Ampita;
use strict;
use warnings;
use Carp;

use version; our $VERSION = '0.008';
# $Id$
# $Version$

## no critic qw(ComplexRegexes EscapedMetacharacters EnumeratedClasses)

my %XML_SPECIAL = (
    q(&) => '&amp;', q(<) => '&lt;', q(>) => '&gt;',
    q(") => '&quot;', q(') => q(&#39;), q(\\) => q(&#92;),
); 
my $ID = qr{[[:alpha:]_:][[:alnum:]_:-]*}msx;
my $SP = q([ \\t\\n\\r]);
my $NL = qr{(?:\r\n?|\n)}msx;
my $ATTR = qr{($SP+)($ID)($SP*=$SP*\")([^<>\"]*)(\")}msx;

sub extend {
    my($class, $base, $selector, $component) = @_;
    my $binding = { %{$base} };
    for my $k (keys %{$component}) {
        $binding->{"$selector $k"} = $component->{$k};
    }
    return $binding;
}

sub generate {
    my($class, $xml, $binding) = @_;
    $class = ref $class || $class;
    my $doc = $class->_scan($xml);
    my $hint = $class->_hint($binding);
    my $idonly = delete $hint->{'##idonly'};
    my $perl = "sub{\n"
        . "my(\$binding)=\@_;\n"
        . "use utf8;\n"
        . "require $class;\n"
        . "my \$r='$class';\n"
        . "my \$t=q();\n";
    my @path;
    my @todo = ($doc, 0);
    my @cont;
    while (@todo) {
        my $i = pop @todo;
        my $node = pop @todo;
        while ($i < @{$node->[1]}) {
            my $child = $node->[1][$i++];
            if (! ref $child) {
                $perl .= $class->_build_data($child);
                next;
            }
            elsif ($child->[0][1] ne q(<)) {
                $perl .= $class->_build_data($class->_data($child));
                next;
            }
            my $key = $class->_find_hint($idonly, $hint, @path, $child->[0]);
            my($build_start, $build_end) =
                $key ? ('_build_scode', '_build_ecode')
                :      ('_build_stag', '_build_etag');
            $perl .= $class->$build_start($child, $key);
            next if $child->[0][5] eq q(/>);
            push @path, $child->[0];
            push @cont, $class->$build_end($child);
            push @todo, $node, $i;
            ($node, $i) = ($child, 0);
        }
        if (@cont) {
            $perl .= pop @cont;
            pop @path;
        }
    }
    return $perl
        . "return \$t;\n"
        . "}\n";
}

sub _scan {
    my($class, $xml) = @_;
    my $document = [
        [q(), q(), q(), [], q(), q(), q()],
        [],
    ];
    my @ancestor;
    my $node = $document;
    while($xml !~ m{\G\z}msxgc) {
        my($t) = $xml =~ m{\G([\x20\t]*)}msxogc;
        if ($xml =~ m{
            \G<
            (?: (?: ($ID) (.*?) ($SP*) (/?>)
                |   /($ID) ($SP*) >
                |   (\?.*?\?|\!(?:--.*?--|\[CDATA\[.*?\]\]|DOCTYPE[^>]+?))>
                )
                ($NL*)
            )?
        }msxogc) {
            my($id1, $t2, $sp3, $gt4, $id5, $sp6, $t7, $nl8)
                = ($1, $2, $3, $4, $5, $6, $7, $8);
            if ($id1) {
                my $attr = [$t2 =~ m{$ATTR}msxog];
                my $element = [
                    [$t, q(<), $id1, $attr, $sp3, $gt4, $nl8],
                    [],
                ];
                push @{$node->[1]}, $element;
                next if $gt4 eq q(/>);
                push @ancestor, $node;
                $node = $element;
                next;
            }
            elsif ($id5) {
                my $id1 = $node->[0][2];
                $id5 eq $id1 or croak "<$id1> ne </$id5>";
                $node->[2] = [$t, q(</), $id5, [], $sp6, q(>), $nl8];
                $node = pop @ancestor;
                next;
            }
            elsif ($t7) {
                push @{$node->[1]}, [
                    [$t, q(), q(), [], "<$t7>", q(), $nl8],
                    [],
                ];
                next;
            }
            else {
                $t .= q(<);
            }
        }
        $t .= $xml =~ m{\G([^<\r\n]+$NL*|$NL+)}msxogc ? $1 : q();
        if (@{$node->[1]} == 0 || ref $node->[1][-1]) {
            push @{$node->[1]}, $t;
        }
        else {
            $node->[1][-1] .= $t;
        }
    }
    @ancestor == 0 or croak 'is not formal XML.';
    return $document;
}

sub _hint {
    my($class, $binding) = @_;
    my $idonly = 1;
    my %hint;
    for my $selector (keys %{$binding}) {
        if ($selector !~ m/\A[\#]$ID\z/msx) {
            $idonly = 0;
        }
        $hint{$selector} = $class->_precompile_selector($selector);
    }
    $hint{'##idonly'} = $idonly;
    return \%hint;
}

sub _precompile_selector {
    my($class, $selector) = @_;
    my @compiled;
    for my $seterm (split /\s+/msx, $selector) {
        if ($seterm =~ m{\A
            ($ID)(?:\#($ID)|[.]([[:alnum:]_:-]+)|\[($ID)([~^\$*|]?=)"([^"]+)"\])?
        |   [*]? (?:\#($ID)|[.]([[:alnum:]_:-]+)|\[($ID)([~^\$*|]?=)"([^"]+)"\])
        \z}mosx) {
            my($tagname, $id, $classname) = ($1, $2 || $7, $3 || $8);
            my($attr, $op, $str) = $id ? ('id', q(=), $id)
                : $classname ? ('class', q(~=), $classname)
                : ($4 || $9, $5 || $10, $6 || $11);
            push @compiled, [$tagname, $attr, $op, $str];
        }
    }
    return \@compiled;
}

sub _find_hint {
    my($class, $idonly, $hint, @path) = @_;
    my $stag = $path[-1];
    if (@{$stag->[3]} && $stag->[3][1] eq 'id') {
        my $tagname = $stag->[2];
        my $id = $stag->[3][3];
        my $se1 = q(#) . $id;
        my $se2 = $tagname . q(#) . $id;
        return $se1 if exists $hint->{$se1};
        return $se2 if exists $hint->{$se2};
        return if $idonly;
    }
    elsif ($idonly) {
        return;
    }
    for my $k (keys %{$hint}) {
        if ($class->_match_selector($hint->{$k}, @path)) {
            return $k;
        }
    }
    return;
}

sub _match_selector {
    my($class, $selector, @path) = @_;
    my @selist = @{$selector};
    return if ! $class->_match_selector_term(pop @selist, pop @path);
    my $seterm = shift @selist or return 1;
    for my $stag (@path) {
        next if ! $class->_match_selector_term($seterm, $stag);
        $seterm = shift @selist or return 1;
    }
    return;
}

sub _match_selector_term {
    my($class, $seterm, $stag) = @_;
    my $element_name = $stag->[2];
    my($tagname, $attr, $op, $str) = @{$seterm};
    return (! $tagname || $element_name eq $tagname)
        && (! $attr || $class->_attr_match($stag, $attr, $op, $str));
}

# see http://www.w3.org/TR/css-2010/#selectors
sub _attr_match {
    my($class, $stag, $attr, $op, $str) = @_;
    my $value = $class->_attr($stag, $attr);
    $value = defined $value ? $value : q();
    if ($op eq q(=)) {
        return $value eq $str;
    }
    if ($op eq q(~=)) {
        return 0 <= index " $value ", " $str ";
    }
    if ($op eq q(^=)) {
        return $str eq (substr $value, 0, length $str);
    }
    if ($op eq qq(\x24=)) {
        my($vsize, $psize) = ((length $value), (length $str));
        return $vsize >= $psize
            && $str eq (substr $value, $vsize - $psize, $psize);
    }
    if ($op eq q(*=)) {
        return 0 <= index $value, $str;
    }
    if ($op eq q(|=)) {
        return 0 <= index "-$value-", "-$str-";
    }
    return $value eq $str;
}

sub _data {
    my($class, $node) = @_;
    if ($node->[0][1] eq q(<)) {
        return exists $node->[1] && ! ref $node->[1][0] ? $node->[1][0] : q();
    }
    else {
        return join q(), @{$node->[0]}[0, 4, 6];
    }
}

sub _build_data {
    my($class, $data) = @_;
    return "\$t.=" . $class->_q($data) . ";\n";
}

sub _build_stag {
    my($class, $element) = @_;
    my $a = $element->[0];
    my $stag = $class->_q(@{$a}[0 .. 2], @{$a->[3]}, @{$a}[4 .. 6]);
    return "\$t.=$stag;\n";
}

sub _build_etag {
    my($class, $element) = @_;
    my $etag = $class->_q(@{$element->[2]}[0 .. 2, 4 .. 6]);
    return "\$t.=$etag;\n";
}

sub _build_scode {
    my($class, $element, $key) = @_;
    my $_attr = join q(,), map { $class->_q($_) } @{$element->[0][3]};
    my $_stag = join q(,),
        (map { $class->_q($_) } @{$element->[0]}[0, 1, 2]),
        q([) . $_attr . q(]),
        (map { $class->_q($_) } @{$element->[0]}[4, 5, 6]);
    my $perl = "\$binding->{" . $class->_q($key) . "}->(sub{\n"
        . "my(\@data) = \@_;\n"
        . "my \$attr = {ref \$data[0] eq 'HASH' ? \%{shift \@data} : ()};\n"
        . "return if (\$attr->{'-skip'} || q()) eq 'all';\n"
        . "\$t.=\$r->_stag([$_stag],\$attr);\n";
    if ($element->[0][5] eq q(/>)) {
        $perl .= $class->_build_argrest($element);
    }
    else {
        my $filter = $class->_choose_filter(
            $class->_data($element) || q(),
            $element->[0][2] eq 'textarea' ? 'xml' : 'text',
        );
        $perl .= "if(\@data){\$t.=\$r->${filter}(join q(),\@data);}else{\n";
    }
    return $perl;
}

sub _build_argrest {
    my($class, $element) = @_;
    return '}, {'
        . (join q(,), map { $class->_q($_) } $class->_attr($element->[0]))
        . '},' . $class->_q($class->_data($element) || q()) . ");\n";
}

sub _build_ecode {
    my($class, $element) = @_;
    my $etag = $class->_q(@{$element->[2]}[0 .. 2, 4 .. 6]);
    return "}\n"
        . "return if \$attr->{'-skip'};\n"
        . "\$t.=$etag;\n"
        . $class->_build_argrest($element);
}

sub _q {
    my($class, @arg) = @_;
    my $s = join q(), @arg;
    $s =~ s/([\\'])/\\$1/msxg;
    return qq('$s');
}

sub _stag {
    my($class, $tmpl, $attr) = @_;
    my $stag = [@{$tmpl}[0 .. 2], [@{$tmpl->[3]}], @{$tmpl}[4 .. 6]];
    if (! $attr->{-skip}) {
        $class->_attr($stag, 'id' => undef);
        while (my($k, $v) = each %{$attr}) {
            next if $k !~ /\A$ID\z/msx;
            $class->_attr($stag, $k => $class->_attr_filter($tmpl, $k, $v));
        }
    }
    if ($stag->[2] eq 'span' && @{$stag->[3]} == 0) {
        $attr->{-skip} = 'tag';
    }
    return q() if $attr->{-skip};
    return join q(), @{$stag}[0 .. 2], @{$stag->[3]}, @{$stag}[4 .. 6];
}

sub _attr {
    my($class, $stag, @arg) = @_;
    my $attr = $stag->[3]; # [(' ', 'name', '="', 'value', '"') ...]
    if (! @arg) {
        my @indecs = map { $_ * 5 } 0 .. -1 + int @{$attr} / 5;
        return map { @{$attr}[$_ + 1, $_ + 3] } @indecs;
    }
    my $name = shift @arg or return;
    my $i = 0;
    while ($i < @{$attr}) {
        if ($attr->[$i + 1] eq $name) {
            return $attr->[$i + 3] if ! @arg;
            if (@arg == 1 && ! defined $arg[0]) {
                my @got = splice @{$attr}, $i, 5;
                return $got[3];
            }
            elsif (@arg) {
                $attr->[$i + 3] = $arg[0];
            }
            return $attr->[$i + 3];
        }
        $i += 5;
    }
    if (@arg && defined $arg[0]) {
        my @got = @{$attr} ? @{$attr}[-5 .. -1]
            : (q( ), q(), q(="), q(), q("));
        $got[1] = $name;
        $got[3] = $arg[0];
        push @{$attr}, @got;
        return $got[3];
    }
    return;
}

my %FILTERS = (
    'URI' => 'uri',
    'URL' => 'uri',
    'HTML' => 'xml',
    'XML' => 'xml',
    'RAW' => 'raw',
    'TEXT' => 'text',
);

sub _choose_filter {
    my($class, $modifier, $default_filter) = @_;
    my $filter = $FILTERS{$modifier} || $default_filter;
    return "_filter_${filter}";
}

sub _attr_filter {
    my($class, $stag, $attrname, $value) = @_;
    return $value if ! defined $value;
    my $tagname = lc $stag->[2];
    my $filter = $class->_choose_filter(
        $class->_attr($stag, $attrname) || q(),
        $tagname eq 'input' && $attrname eq 'value' ? 'xml'
        : $attrname =~ /(?:\A(?:action|src|href|cite)|resource)\z/msxi ? 'uri'
        : 'text',
    );
    return $class->$filter($value);
}

sub _filter_raw { return $_[1] }

sub _filter_xml {
    my($class, $t) = @_;
    $t = defined $t ? $t : q();
    $t =~ s{([<>"'&\\])}{ $XML_SPECIAL{$1} }egmsx;
    return $t;
}

sub _filter_text {
    my($class, $t) = @_;
    $t = defined $t ? $t : q();
    $t =~ s{
        (?:([<>"'\\])
        |   \&(?:([[:alpha:]_][[:alnum:]_]*
            |\#(?:[[:digit:]]{1,5}|x[[:xdigit:]]{2,4}));
            )?
        )
    }{
        $1 ? $XML_SPECIAL{$1} : $2 ? qq(\&$2;) : q(&amp;)
    }egmosx;
    return $t;
};

sub _filter_uri {
    my($class, $t) = @_;
    $t = defined $t ? $t : q();
    if (utf8::is_utf8($t)) {
        require Encode;
        $t = Encode::encode('utf-8', $t);
    }
    $t =~ s{
        (%([[:xdigit:]]{2})?)|(&(?:amp;)?)|([^[:alnum:]\-_~*+=/.!,;:\@?\#])
    }{
        $2 ? $1 : $1 ? q(%25) : $3 ? q(&amp;) : sprintf q(%%%02X), ord $4
    }egmosx;
    return $t;
}

1;

__END__

=pod

=head1 NAME

Text::Ampita - Template generator from a xhtml document and runtime for it.

=head1 VERSION

0.008

=head1 SYNOPSIS

    use Text::Ampita;
    use Time::Piece;
    use Encode;

    my $xhtml = <<'XHTML';
    <div class="hentry">
     <h2></h2>
     <div id="entry-body">RAW</div>
     <div id="entry-date">%Y-%m-%d %H:%M</div>
    </div>
    XHTML

    my $binding = sub{
        my @entries = (
            {title => 'FOO', body => '<b>foo</b> is foo', date => time - 120},
            {title => 'BAR', body => 'bar is bar', date => time - 60},
            {title => 'BAZ', body => 'baz is baz', date => time},
        );
        my $entry;
        return {
            '.hentry' => sub{
                my($yield) = @_;
                for (@entries) {
                    $entry = $_;
                    $yield->();
                }
            },
            'h2' => sub{
                shift->($entry->{title});
            },
            '#entry-body' => sub{
                shift->({class => 'content'}, $entry->{body});
            },
            '#entry-date' => sub{
                my($yield, $attr, $data) = @_;
                my $ustrtime = gmtime($entry->{date})->strftime('%FT%TZ');
                my $lstrtime = decode('utf-8', 
                    localtime($entry->{date})->strftime(encode('utf-8', $data)),
                );
                $yield->({title => $ustrtime, class => 'published'}, $lstrtime);
            },
        };
    }->();

    my $tmplpkg = "Text::Ampita::Jail" . (int rand 100000);
    my $perl = "package $tmplpkg;" . Text::Ampita->generate($xhtml, $binding);
    my $template = eval $perl;
    print encode('utf-8', $template->($binding));

=head1 DESCRIPTION

This module provides you to manipurate a XHTML document as
a template without special markups in it.

=head1 METHODS 

=over

=item C<< $binding = $class->extend($orig_binding, $selector, $component) >>

Creates new binding hash reference mixed oringinal one with component.

=item C<< $template_src = $class->generate($xhtml, $binding) >>

Generates a perl code reference declaration from a given XHTML text
and a binding hash referenece. The code reference requires Text::Ampita
itself at running.

=item C<< $xhtml = (eval $template_src)->($binding) >>

Creates a XHTML text from the template.

=back

=head1 DEPENDENCIES

L<Encode>
L<Carp>

=head1 SEE ALSO

L<http://amrita.sourceforge.jp/index.html>

=head1 AUTHOR

MIZUTANI Tociyuki  C<< <tociyuki@gmail.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2011, MIZUTANI Tociyuki C<< <tociyuki@gmail.com> >>.
All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
