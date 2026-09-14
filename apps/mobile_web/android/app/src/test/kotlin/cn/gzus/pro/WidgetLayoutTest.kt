package cn.gzus.pro

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.w3c.dom.Node

class WidgetLayoutTest {
    @Test
    fun smallWidgetContentTitleUsesVisibleHeight() {
        val layoutPath = Path.of("src/main/res/layout/widget_home_card_small.xml")
        val document = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(Files.newInputStream(layoutPath))
        val textViews = document.getElementsByTagName("TextView")
        var title: Node? = null
        for (index in 0 until textViews.length) {
            val node = textViews.item(index)
            if (node.attributes.getNamedItem("android:id")?.nodeValue == "@+id/widget_content_title") {
                title = node
                break
            }
        }
        assertNotNull(title)
        val titleNode = requireNotNull(title)

        assertEquals("wrap_content", titleNode.attributes.getNamedItem("android:layout_height")?.nodeValue)
        assertFalse(titleNode.attributes.getNamedItem("android:layout_weight") != null)
    }
}
