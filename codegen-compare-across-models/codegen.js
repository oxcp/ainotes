document.addEventListener('DOMContentLoaded', function() {
  // 高亮 panel A 的选中项
  document.querySelectorAll('.panel-a li').forEach(function(item) {
    item.addEventListener('click', function() {
      document.querySelectorAll('.panel-a li').forEach(function(li) {
        li.classList.remove('active');
      });
      this.classList.add('active');
    });
  });

  // --- Splitter logic ---
  // Panel A <-> right-section
  const panelA = document.getElementById('panel-a');
  const rightSection = document.getElementById('right-section');
  const splitterAB = document.getElementById('splitter-a-b');
  let isDraggingAB = false;
  splitterAB.addEventListener('mousedown', function(e) {
      isDraggingAB = true;
      document.body.style.cursor = 'col-resize';
  });
  document.addEventListener('mousemove', function(e) {
      if (!isDraggingAB) return;
      const minWidth = 120;
      const maxWidth = window.innerWidth - 200;
      let newWidth = e.clientX;
      if (newWidth < minWidth) newWidth = minWidth;
      if (newWidth > maxWidth) newWidth = maxWidth;
      panelA.style.width = newWidth + 'px';
  });
  document.addEventListener('mouseup', function() {
      if (isDraggingAB) {
          isDraggingAB = false;
          document.body.style.cursor = '';
      }
  });

  // Panel B <-> bottom-panels (vertical split)
  const panelB = document.getElementById('panel-b');
  const splitterBC = document.getElementById('splitter-b-cd');
  const bottomPanels = document.getElementById('bottom-panels');
  let isDraggingBC = false;
  splitterBC.addEventListener('mousedown', function(e) {
      isDraggingBC = true;
      document.body.style.cursor = 'row-resize';
  });
  document.addEventListener('mousemove', function(e) {
      if (!isDraggingBC) return;
      const containerRect = document.querySelector('.container').getBoundingClientRect();
      let y = e.clientY - containerRect.top;
      const minPanelB = 60;
      const minBottom = 60;
      const maxY = containerRect.height - minBottom;
      if (y < minPanelB) y = minPanelB;
      if (y > maxY) y = maxY;
      panelB.style.flexBasis = y + 'px';
      bottomPanels.style.flexBasis = (containerRect.height - y - splitterBC.offsetHeight) + 'px';
  });
  document.addEventListener('mouseup', function() {
      if (isDraggingBC) {
          isDraggingBC = false;
          document.body.style.cursor = '';
      }
  });

  // Panel C <-> D (horizontal split)
  const panelC = document.getElementById('panel-c');
  const panelD = document.getElementById('panel-d');
  const splitterCD = document.getElementById('splitter-c-d');
  let isDraggingCD = false;
  splitterCD.addEventListener('mousedown', function(e) {
      isDraggingCD = true;
      document.body.style.cursor = 'col-resize';
  });
  document.addEventListener('mousemove', function(e) {
      if (!isDraggingCD) return;
      const bottomRect = bottomPanels.getBoundingClientRect();
      let x = e.clientX - bottomRect.left;
      const minC = 80;
      const minD = 80;
      const maxX = bottomRect.width - minD;
      if (x < minC) x = minC;
      if (x > maxX) x = maxX;
      panelC.style.flex = 'none';
      panelC.style.width = x + 'px';
      panelD.style.flex = '1';
  });
  document.addEventListener('mouseup', function() {
      if (isDraggingCD) {
          isDraggingCD = false;
          document.body.style.cursor = '';
      }
  });
});


let panelA_selected_item = "";
function showMessage(item) {
    panelA_selected_item = item;
    loadContent("prompts/prompts-" + item + ".yaml", 'panel-b-content');
    loadContent("output/response-gpt5-" + item + ".txt", 'panel-c-content');
    refreshNonGPTMessage(item);
}

function refreshNonGPTMessage(item) {
    // const panelDContent = document.getElementById('panel-d-content');
    // panelDContent.textContent = `Response from ${selectedModel} here:`;
    selectedModel = document.getElementById('model-select').value;
    loadContent("output/response-" + selectedModel + "-" + item + ".txt", 'panel-d-content');    

}

function handleModelSelect(event) {
    const select = event.target;

    if (panelA_selected_item === "") {
        const selectedText = select.options[select.selectedIndex].text;
        document.getElementById('panel-d-content').innerHTML = `Response from <span id="selected-model-text">${selectedText}</span> here:`;
    } else {
        refreshNonGPTMessage(panelA_selected_item);
    }
}

// function to load content from file, and return the content as text
async function loadContent(url, elementid) {
    fetch(url) //1
    .then((response) => response.text()) //2
    .then((info) => {
        document.getElementById(elementid).textContent = info; //3
        //console.log(info);
    });
}
