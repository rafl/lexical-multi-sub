use strict;
use warnings;

package Lexical::Multi::Sub;

use XSLoader;
use Carp 'confess', 'croak';
use Class::MOP;
use Devel::PartialDump 'dump';
use Lexical::Sub ();
use B::Hooks::EndOfScope ();
use Parse::Method::Signatures;
use Moose::Util 'does_role';
use MooseX::Types::Moose qw(ArrayRef Any);
use MooseX::Types::Structured qw(Tuple Optional slurpy);
use aliased 'MooseX::Types::VariantTable';
use aliased 'Parse::Method::Signatures::Param::Placeholder';

XSLoader::load(__PACKAGE__);

sub import {
    my ($pkg) = @_;
    $^H{"Lexical::Multi::Sub/multi"} = 1;
}

sub _analyse_sig {
    my ($sig) = @_;

    my $parsed = Parse::Method::Signatures->signature(sprintf "(%s)", $sig);
    # FIXME: make sure the signature is simple enough

    return $parsed;
}

sub _injectable_code {
    my ($sig) = @_;

    my @lexicals;

    push @lexicals,
        (does_role($_, Placeholder)
            ? 'undef'
            : $_->variable_name)
        for (($sig->has_positional_params ? $sig->positional_params : ()),
             ($sig->has_named_params      ? $sig->named_params      : ()));

    my $vars = join q{,}, @lexicals;
    return "my(${vars})=\@_;";

}

sub _param_to_spec {
    my ($param) = @_;

    my $tc = Any;
    $tc = $param->meta_type_constraint
        if $param->has_type_constraints;

    if ($param->has_constraints) {
        my $cb = join ' && ', map { "sub {${_}}->(\\\@_)" } $param->constraints;
        my $code = eval "sub {${cb}}";
        $tc = subtype({ as => $tc, where => $code });
    }

    my %spec;
    if ($param->sigil ne '$') {
        $spec{slurpy} = 1;
        $tc = slurpy ArrayRef[$tc];
    }

    $spec{tc} = $param->required ? $tc : Optional[$tc];

    $spec{default} = $param->default_value
        if $param->has_default_value;

    return \%spec;
}

sub _sig_type_constraint {
    my ($sig) = @_;

    my @positional;

    my $slurpy = 0;
    if ($sig->has_positional_params) {
        for my $param ($sig->positional_params) {
            my $spec = _param_to_spec($param);
            $slurpy ||= 1 if $spec->{slurpy};
            push @positional, $spec;
        }
    }

    return Tuple[
        map { $_->{tc} } @positional,
    ];
}

sub _register {
    my ($cv) = @_;
    my ($name, $sig) = @^H{map {
        "Lexical::Multi::Sub/compiling_${_}" } qw(name sig)
    };

    my $variant_table = $^H{"Lexical::Multi::Sub/&${name}"};
    $variant_table->add_variant(_sig_type_constraint($sig), [$sig, $cv]);
}

sub _declare {
    my ($name, $sig) = @_;

    return if $^H{"Lexical::Multi::Sub/&${name}"};

    my $variant_table = VariantTable->new(
        ambigious_match_callback => sub {
            my ($self, $value, @matches) = @_;
            local $Carp::CarpLevel = 2;
            croak sprintf 'Ambiguous match for multi method %s: %s with value %s',
                $name,
                join(q{, }, map { $_->{value}->[0]->to_string } @matches),
                dump($value);
        },
    );

    $^H{"Lexical::Multi::Sub/&${name}"} = $variant_table;

    Lexical::Sub->import($name => sub {
        my ($args) = \@_;

        my $result = $variant_table->find_variant($args);
        confess "no variant of method '${name}' found for ", dump($args)
            unless $result;

        goto $result->[1];

    });
}

1;
