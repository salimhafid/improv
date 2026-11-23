"""UCB section pages include course copy, instructor bios and other date cards."""
import unittest
from unittest.mock import patch

from sources import ucb_classes


class UcbClassDetailTests(unittest.TestCase):
    def test_only_the_selected_sections_course_copy_is_enriched(self):
        html = """<h1 class="ucb-class-band__title">Improv 101</h1>
        <section class="ucb-class-about"><h2>About this class</h2><div class="ucb-class-about__body">
        <p>Build group mind.</p><p>Eight classes and a final show.</p></div></section>
        <div class="ucb-class-instructor__bio">Teacher bio.</div>"""
        with patch.object(ucb_classes, 'fetch_html', return_value=html):
            self.assertEqual(ucb_classes.class_detail('https://ucbcomedy.com/course/improv-101/1001/'),
                             {'description': 'Build group mind.\n\nEight classes and a final show.'})

    def test_generic_course_redirect_retries_missing_section(self):
        with patch.object(ucb_classes, 'fetch_html', return_value='<h1 class="ucb-co-title">Improv</h1>'):
            self.assertIsNone(ucb_classes.class_detail('https://ucbcomedy.com/course/improv-101/1001/'))
