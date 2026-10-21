require 'pupgrade/logging'

module Pupgrade
  module CLI
    # Plain-text table output, columns left-aligned. Cells may carry ANSI
    # colour; widths count the visible characters.
    module Table
      ANSI = /\e\[[0-9;]*m/

      # Prints a header, a rule, and one line per row.
      #
      # @param columns [Array<String>] header cells
      # @param rows [Array<Array<String>>] one cell per column
      def print_table(columns, rows)
        if rows.empty?
          puts '(nothing matches)'
          return
        end
        widths = columns.each_index.map { |i| ([columns[i]] + rows.map { |r| r[i] }).map { |c| visible(c).length }.max }
        puts align(columns, widths)
        puts widths.map { |w| '-' * w }.join('-+-')
        rows.each { |r| puts align(r, widths) }
      end

      # The text coloured when stdout takes colour, else as given.
      def paint(text, *styles)
        ::Pupgrade::Ansi.enabled?($stdout) ? ::Pupgrade::Ansi.wrap(text, *styles) : text.to_s
      end

      private

      def visible(cell)
        cell.to_s.gsub(ANSI, '')
      end

      def align(cells, widths)
        cells.each_with_index.map { |c, i| c.to_s + (' ' * [widths[i] - visible(c).length, 0].max) }.join(' | ').rstrip
      end
    end
  end
end
