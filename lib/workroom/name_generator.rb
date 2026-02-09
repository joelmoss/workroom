# frozen_string_literal: true

module Workroom
  class NameGenerator
    ADJECTIVES = %w[
      agile amber apt azure bold brave bright brisk calm cedar clear cold cool
      coral crisp cyan damp dark dawn deep deft dry dusk dusty easy even fair
      fast firm flat fond free fresh full glad gold good gray green hale happy
      hazy high idle jade keen kind lark last lean left light lime long lost
      loud lush mild mint misty mossy neat nice noble north novel oak odd opal
      open pale peak pine pink plum proud pure quick quiet rapid rare red rich
      ripe rosy ruby safe sage salt sharp shy silk slim slow smart snowy soft
      solid south stark steel still stout sunny sure swift tall tame teal thin
      tidy trim true vivid warm west wide wild wise young
    ].freeze

    NOUNS = %w[
      acre arch aspen badge bank bark basin bay beach bear birch blade blaze
      bloom bolt bone bow brace brass breeze brick bridge brook brush canopy
      cape cave cedar chain chime cliff cloud clover colt coop coral core
      cove crane creek crest crow curve dale dawn deer delta dew dock dove
      drake drift dune dusk eagle edge elm ember fawn feather fern field finch
      fjord flame flask flint float flora flute fog font forge fox frost gate
      glade glen globe gorge grain grove gulf gust hare haven hawk hazel
      heath hedge heron hill hollow horn inlet isle ivy jade jewel knoll
      lake larch lark latch laurel leaf ledge light lilac lily linen lodge
      loft lynx maple marsh meadow mesa mint mirror mist moon moss mound
      nest north oak opal orbit orion otter palm pass path peak pearl
      pebble perch petal pine pixel plume pond pool porch prism quail
      quarry quartz rail rain raven reef ridge river robin rock root rose
      ruby sage sand scope seal seed shade shell shore silk sky slate
      slope smoke snow south spark spire spoke spring spruce star stem
      stone stork storm strand surf swift tern thyme tide timber tower
      trail tree vale vault vine vista wand ward wave west wheat willow
      wind wing wolf wren yard
    ].freeze

    def generate
      "#{ADJECTIVES.sample}-#{NOUNS.sample}"
    end
  end
end
