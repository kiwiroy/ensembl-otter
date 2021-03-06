package Test::Bio::Vega;

use Test::Class::Most
    parent      => 'OtterTest::Class',
    is_abstract => 1,
    attributes  => [ qw( test_region parsed_region ) ];

sub startup : Test(startup => +0) {
    my $test = shift;
    $test->SUPER::startup;

    my $features = $test->test_bio_vega_features;
    if ($features->{test_region} or $features->{parsed_region}) {
        require OtterTest::TestRegion;
        $test->test_region(OtterTest::TestRegion->new(1)); # we use the second more complex region
    }

    return;
}

sub setup : Tests(setup) {
    my $test = shift;
    $test->SUPER::setup;

    my $features = $test->test_bio_vega_features;
    if ($features->{parsed_region}) {

        my $bvt_x2r = $test->get_bio_vega_transform_xmltoregion;
        $bvt_x2r->coord_system_factory($test->get_coord_system_factory);

        my $region = $bvt_x2r->parse($test->test_region->xml_region);
        $test->parsed_region($region);
    }

    return;
}

# Overrideable - default is a plain in-memory one
#
sub get_coord_system_factory {
    require Bio::Vega::CoordSystemFactory;
    return Bio::Vega::CoordSystemFactory->new;
}

sub get_bio_vega_transform_xmltoregion {
    require Bio::Vega::Transform::XMLToRegion;
    return Bio::Vega::Transform::XMLToRegion->new;
}

sub test_bio_vega_features {
    return {
        test_region   => 0,
        parsed_region => 0,
    };
}

1;
